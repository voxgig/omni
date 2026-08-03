;; Omni: the shared multi-language test runner (Clojure port).
;;
;; Port of the canonical TypeScript implementation
;; (typescript/src/Runner.ts). Behaviour must match, case for case.

(ns voxgig.omni.runner
  (:require [clojure.string :as string]
            [voxgig.omni.json :as json]
            [voxgig.omni.util :as u])
  (:import [java.io File]
           [java.util.regex Pattern PatternSyntaxException]))

;; A test failure (or a malformed spec). Distinct from errors thrown by the
;; subject under test, which are candidates for an `err` expectation.
(defn omni-error
  ([message] (omni-error message nil))
  ([message entry]
   (ex-info message {:omni true :entry entry})))

(defn omni-error? [err]
  (and (instance? clojure.lang.IExceptionInfo err) (:omni (ex-data err))))

;; Load a spec: a path to a JSON file.
(defn loadspec [path]
  (when-not (.exists (File. ^String path))
    (throw (omni-error (str "omni: cannot read spec: " path))))
  (json/parse (slurp path)))

;; Find `primary.<name>`, then `<name>`, then the whole spec.
(defn resolvespec [name alltests]
  (if (or (nil? name) (= "" name))
    alltests
    (let [primary (get-in alltests ["primary" name])]
      (cond
        (some? primary) primary
        (some? (get alltests name)) (get alltests name)
        :else alltests))))

;; Nulls (and absent values) become NULLMARK. Always a fresh copy.
(defn fixjson [val donull]
  (cond
    (u/isnone val) (if donull u/NULLMARK nil)
    (u/islist val) (vec (map #(fixjson % donull) val))
    (u/ismap val) (reduce-kv (fn [out key entry] (assoc out key (fixjson entry donull)))
                             (array-map)
                             val)
    :else val))

;; The JSON form of an error: always at least {name,message}.
(defn errmessage [err]
  (or (ex-message err) (.getSimpleName (class err))))

(defn errify [err]
  (array-map "name" (.getSimpleName (class err)) "message" (errmessage err)))

;; Match one leaf: /regex/ or case-insensitive substring for strings.
(defn matchval [check base]
  (if (u/deepequal check base)
    true
    (let [want (if (or (= u/UNDEFMARK check) (= u/NULLMARK check)) nil check)]
      (cond
        (nil? want) (or (u/isnone base) (= u/NULLMARK base))

        ;; An empty want is a substring of everything, so it would match any
        ;; value. Require the base to be the empty string too.
        (= "" want) (= "" base)

        (string? want)
        (let [basestr (u/stringify base)]
          (if (and (< 2 (count want)) (string/starts-with? want "/") (string/ends-with? want "/"))
            (try
              (.find (.matcher (Pattern/compile (subs want 1 (dec (count want)))) basestr))
              (catch PatternSyntaxException _ false))
            (string/includes? (string/lower-case basestr) (string/lower-case want))))

        :else (u/deepequal want base)))))

;; Convert NULLMARK sentinels back into real nulls.
(defn nullmodifier [val _path]
  (cond
    (= u/NULLMARK val) nil
    (string? val) (string/replace val u/NULLMARK "null")
    :else val))

;; The spec-defined part of an entry (drop runner bookkeeping).
(defn- entrysummary [entry]
  (reduce-kv (fn [out key value]
               (if (contains? #{"res" "thrown" "ctx"} key) out (assoc out key value)))
             (array-map)
             entry))

;; The label of one entry, for failure messages.
(defn- entryref [label index entry]
  (let [id (get entry "id")]
    (str label "[" index "]" (if (some? id) (str " (" (u/stringify id) ")") ""))))

(defn- fail
  ([label index entry reason] (fail label index entry reason nil nil))
  ([label index entry reason expected actual]
   (let [msg (str "omni: " (entryref label index entry) ": " reason
                  (if (some? expected) (str "\n  expected: " expected) "")
                  (if (some? actual) (str "\n  actual:   " actual) "")
                  "\n  entry:    " (u/stringify (entrysummary entry)))]
     (omni-error msg entry))))

;; Check that every leaf of `check` is present, and matches, in `base`.
(defn match
  ([label index entry check base] (match label index entry check base []))
  ([label index entry check base path]
   (let [at (if (empty? path) "<root>" (u/pathify path))]
     (cond
       ;; An empty container asserts structure that the traversal would
       ;; otherwise skip: it has no leaves, so `match:{out:{}}` used to pass
       ;; any result. Require the base at this path to be an equal empty
       ;; container. (The synthetic root wrapper is never empty, so skip it.)
       (and (u/isnode check) (seq path) (empty? check))
       (let [baseval (u/getpath base path)]
         (when-not (u/deepequal check baseval)
           (throw (fail label index entry (str "match failed at " at)
                        (u/stringify check) (u/stringify baseval)))))

       (u/islist check)
       (doseq [[index2 subcheck] (map-indexed vector check)]
         (match label index entry subcheck base (conj path (str index2))))

       (u/ismap check)
       (doseq [[key subcheck] check]
         (match label index entry subcheck base (conj path key)))

       :else
       (let [baseval (u/getpath base path)]
         (cond
           (u/deepequal check baseval) nil

           ;; Explicitly absent: satisfied only by a genuinely missing key,
           ;; never by a present null (the distinction the sentinels exist
           ;; to keep).
           (= u/UNDEFMARK check)
           (when-not (u/isabsent baseval)
             (throw (fail label index entry (str "expected absent at " at)
                          "absent" (u/stringify baseval))))

           ;; Explicitly null: satisfied only by a present null.
           (= u/NULLMARK check)
           (when-not (or (nil? baseval) (= u/NULLMARK baseval))
             (throw (fail label index entry (str "expected null at " at)
                          "null" (u/stringify baseval))))

           ;; Explicitly present: any present value, including null.
           (= u/EXISTSMARK check)
           (when (u/isabsent baseval)
             (throw (fail label index entry (str "expected present at " at)
                          "present" "absent")))

           ;; A concrete expectation never matches a missing key - a match
           ;; leaf against an absent value must fail, not substring-match
           ;; the text "undefined".
           (u/isabsent baseval)
           (throw (fail label index entry (str "match failed at " at)
                        (u/stringify check) "absent"))

           (not (matchval check baseval))
           (throw (fail label index entry (str "match failed at " at)
                        (u/stringify check) (u/stringify baseval)))))))))

(defn- checkresult [label index entry args res]
  (let [entryerr (get entry "err")
        check (get entry "match")]

    (when (some? entryerr)
      (throw (fail label index entry "expected error did not occur"
                   (u/stringify entryerr) (u/stringify res))))

    (when (some? check)
      (match label index entry check
             (array-map "in" (get entry "in")
                        "args" (vec args)
                        "out" (get entry "res")
                        "ctx" (get entry "ctx"))))

    (let [out (get entry "out")]
      (cond
        (u/deepequal res out) nil

        ;; NOTE: a match with no explicit out is a complete check on its own.
        (and (some? check) (or (nil? out) (= u/NULLMARK out))) nil

        :else (throw (fail label index entry "result mismatch"
                           (u/stringify out) (u/stringify res)))))))

(defn- handleerror [label index entry err]
  (let [entryerr (get entry "err")]
    (if (some? entryerr)
      (if (or (true? entryerr) (matchval entryerr (errmessage err)))
        (when-let [check (get entry "match")]
          (match label index entry check
                 (array-map "in" (get entry "in")
                            "out" (get entry "res")
                            "ctx" (get entry "ctx")
                            "err" (errify err))))
        (throw (fail label index entry "error mismatch"
                     (u/stringify entryerr) (errmessage err))))
      (throw (fail label index entry "unexpected error" nil (errmessage err))))))

;; Build the argument list: `ctx`, `args`, or `in`.
(defn- resolveargs [entry provider]
  (let [hasctx (contains? entry "ctx")
        hasargs (contains? entry "args")
        args (cond
               hasctx [(get entry "ctx")]
               hasargs (let [raw (get entry "args")] (if (u/islist raw) (vec raw) [raw]))
               :else [(u/clone (get entry "in"))])]

    (if (and (or hasctx hasargs) (seq args) (u/ismap (first args)))
      (let [contextify (:contextify provider)
            first-arg (if contextify (contextify (first args)) (first args))]
        [(assoc args 0 first-arg) (assoc entry "ctx" first-arg)])
      [args entry])))

(defn- run-set-flags [runpack testspec flags testsubject]
  (let [{:keys [spec subject provider clients name]} runpack
        donull (if (contains? flags :null) (boolean (:null flags)) true)
        label (or (:name flags) (if (string/blank? name) "set" name))
        usesubject (or testsubject subject)]

    (when (nil? usesubject)
      (throw (omni-error (str "omni: no test subject for: " label))))

    (let [testspecmap (fixjson testspec donull)
          testset (get testspecmap "set")]

      (when-not (u/islist testset)
        (throw (omni-error (str "omni: test spec has no set: " label))))

      (doseq [[index rawentry] (map-indexed vector testset)]
        (when-not (u/ismap rawentry)
          (throw (omni-error (str "omni: " label "[" index "]: entry is not a map"))))

        ;; An entry with no `out` expects a null (or absent) result.
        (let [entry (if (and donull (nil? (get rawentry "out")))
                      (assoc rawentry "out" u/NULLMARK)
                      rawentry)

              clientname (get entry "client")
              client (when (some? clientname)
                       (or (get clients clientname)
                           (throw (omni-error (str "omni: unknown client: " clientname) entry))))

              entrysubject (or (when client ((or (:subject client) (constantly nil)) name))
                               usesubject)

              [args withctx] (resolveargs entry provider)]

          (try
            (let [res (fixjson (entrysubject args) donull)
                  done (assoc withctx "res" res)]
              (checkresult label index done args res))
            (catch Throwable err
              (if (omni-error? err)
                (throw err)
                (handleerror label index withctx err)))))))))

;; What a runner returns for one named spec section.
(defn- make-runpack [spec subject provider clients name]
  (let [runpack {:spec spec :subject subject :provider provider
                 :clients clients :name name :client provider}]
    (assoc runpack
           :set (fn [setname] (get spec setname))
           :runsetflags (fn [testspec flags testsubject]
                          (run-set-flags runpack testspec flags testsubject))
           :runset (fn [testspec testsubject]
                     (run-set-flags runpack testspec {} testsubject)))))

;; Make a runner for a spec file path (or spec value) and a provider.
(defn make-runner
  ([specref] (make-runner specref {}))
  ([specref provider]
   (let [alltests (if (string? specref) (loadspec specref) specref)]
     (fn runner
       ([name] (runner name nil))
       ([name store]
        (let [spec (resolvespec name alltests)
              defclient (get-in spec ["DEF" "client"])
              clientmaker (:client provider)

              ;; A spec may define clients that a run never references.
              clients (if (and (u/ismap defclient) clientmaker)
                        (reduce-kv
                         (fn [out clientname cdef]
                           (let [copts (or (get-in cdef ["test" "options"]) (array-map))
                                 injector (:inject provider)
                                 copts (if (and injector (u/ismap store))
                                         (injector copts store)
                                         copts)]
                             (assoc out clientname (clientmaker copts))))
                         {}
                         defclient)
                        {})

              subject (when-let [resolve-subject (:subject provider)] (resolve-subject name))]

          (make-runpack spec subject provider clients name)))))))
