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

;; The newest spec format version this runner understands. A spec with no
;; OMNI block is version 0: the original, lenient format, frozen forever.
;; Version 1 turns on strict entry validation (see checkentry).
(def SPECVERSION 1)

;; Capability strings this runner supports beyond the version baseline. A
;; spec's OMNI.requires list is checked against this: an unknown capability
;; refuses the spec loudly at load time, instead of a lagging port silently
;; mis-running it. (Empty today; future format features mint a string here.)
(def CAPABILITIES [])

;; The complete set of fields an entry may carry. Under version 1 anything
;; else is an error: an unrecognised key is almost always a typo'd
;; assertion, and a typo'd assertion is a test that silently stopped
;; testing.
(def ^:private ENTRYFIELDS #{"in" "args" "ctx" "out" "err" "match" "client" "id" "doc"})

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

;; Read the spec's format version from its optional top-level OMNI block,
;; and refuse a spec this runner cannot faithfully run: a version newer
;; than SPECVERSION, or a required capability not in CAPABILITIES. A
;; genuinely absent OMNI key is legacy (version 0); a present-but-null
;; block is malformed - presence, not nil-ness, decides.
(defn- resolveversion [alltests]
  (if-not (and (u/ismap alltests) (contains? alltests "OMNI"))
    0
    (let [meta (get alltests "OMNI")
          version (when (u/ismap meta) (get meta "version"))]

      (when-not (and (u/ismap meta) (u/isnum version) (== version (Math/rint (double version))))
        (throw (omni-error "omni: malformed OMNI version block")))

      (when (or (< version 0) (< SPECVERSION version))
        (throw (omni-error (str "omni: unsupported spec version: " (u/numstr version)))))

      (when (contains? meta "requires")
        (let [requires (get meta "requires")]
          (when-not (u/islist requires)
            (throw (omni-error "omni: malformed OMNI requires list")))
          (doseq [cap requires]
            (when-not (and (string? cap) (contains? (set CAPABILITIES) cap))
              (throw (omni-error (str "omni: spec requires unsupported capability: " (u/stringify cap))))))))

      (long version))))

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
    ;; Canonical returns the value UNCHANGED when donull is false
    ;; (typescript/src/Runner.ts): absent stays absent and nil stays nil.
    ;; Answering nil for both collapsed two states the corpus distinguishes,
    ;; so a subject that correctly returned nothing was compared against null
    ;; and marked wrong. Same defect the other ports carried (#17, #23, #25,
    ;; #26, #27, #28).
    (u/isnone val) (if donull u/NULLMARK val)
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

;; The spec-defined part of an entry (drop runner bookkeeping). A non-map
;; entry (e.g. checkentry's "entry is not a map" failure) has nothing to
;; strip, so it passes through unchanged.
(defn- entrysummary [entry]
  (if-not (u/ismap entry)
    entry
    (reduce-kv (fn [out key value]
                 (if (contains? #{"res" "thrown" "ctx"} key) out (assoc out key value)))
               (array-map)
               entry)))

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

;; Strict entry validation, applied when the spec declares version 1 or
;; later. The lenient format converts each of these mistakes into a silent
;; pass or a dead field; here they fail with the entry named.
(defn- checkentry [label index entry]
  (when-not (u/ismap entry)
    (throw (fail label index entry "entry is not a map")))

  (doseq [key (keys entry)]
    (when-not (contains? ENTRYFIELDS key)
      (throw (fail label index entry (str "unknown entry field: " key)))))

  (let [argsources (count (filter #(contains? entry %) ["in" "args" "ctx"]))]
    (when (< 1 argsources)
      (throw (fail label index entry "entry has more than one of in, args, ctx"))))

  (when (and (some? (get entry "err")) (contains? entry "out"))
    (throw (fail label index entry "entry has both err and out")))

  (when (and (contains? entry "id") (not (string? (get entry "id"))))
    (throw (fail label index entry "entry id is not a string"))))

;; Validate a version-1 group up front, against the AUTHORED entries -
;; null-normalisation would otherwise rewrite an authored null (e.g.
;; id: null) into a sentinel string and hide it from validation. A
;; malformed spec is a spec error, not a test result, so it fails before
;; any subject runs.
(defn- checkset [label testspec normalset]
  (let [origset (if (and (u/ismap testspec) (u/islist (get testspec "set")))
                  (get testspec "set")
                  normalset)]

    (when (and (zero? (count origset))
               (not (true? (when (u/ismap testspec) (get testspec "empty")))))
      (throw (omni-error (str "omni: empty test set: " label))))

    (doseq [[index entry] (map-indexed vector origset)]
      (checkentry label index entry))))

;; Check that every leaf of `check` is present, and matches, in `base`.
(defn match
  ([label index entry check base] (match label index entry check base []))
  ([label index entry check base path]
   (let [at (if (empty? path) "<root>" (u/pathify path))]
     (cond
       (u/islist check)
       (doseq [[index2 subcheck] (map-indexed vector check)]
         (match label index entry subcheck base (conj path (str index2))))

       (u/ismap check)
       (doseq [[key subcheck] check]
         (match label index entry subcheck base (conj path key)))

       :else
       (let [baseval (u/getpath base path)]
         (cond
           ;; The sentinels are tested BEFORE the identity check below.
           ;; Otherwise a subject returning the literal string "__UNDEF__"
           ;; satisfies an assertion that the key is absent - two mutually
           ;; exclusive states passing one check. A sentinel that accepts
           ;; its own literal is not a sentinel. (NULLMARK still accepts
           ;; NULLMARK: under the default null flag a real null has already
           ;; been normalised to it, so the two are genuinely
           ;; indistinguishable here - that one needs a raw-value escape,
           ;; not an ordering change.)

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

           ;; Identical values match. This sits below the sentinel branches
           ;; on purpose - see the note above.
           (u/deepequal check baseval) nil

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

;; Build the argument list: `ctx`, `args`, or `in`. A leading map argument
;; is passed through `provider.contextify` and has the active client
;; attached under `client`, mirroring canonical resolveargs.
(defn- resolveargs [entry provider client]
  (let [hasctx (contains? entry "ctx")
        hasargs (contains? entry "args")
        args (cond
               hasctx [(get entry "ctx")]
               hasargs (let [raw (get entry "args")] (if (u/islist raw) (vec raw) [raw]))
               ;; ABSENT, not nil, when the entry supplies no `in`: a Clojure
               ;; map read answers nil for a missing key and for an authored
               ;; `in: null` alike, and the corpus distinguishes them -
               ;; struct's `minor/typify` has both `{in: null, out: <T_null>}`
               ;; and `{out: <T_noval>}` (register 4.12). The typed ports get
               ;; this for free because their map read returns their own
               ;; absent marker; the dynamic ones have to say it.
               :else [(u/clone (if (contains? entry "in") (get entry "in") u/ABSENT))])]

    (if (and (or hasctx hasargs) (seq args) (u/ismap (first args)))
      (let [contextify (:contextify provider)
            first-arg (if contextify (contextify (first args)) (first args))
            ;; contextify may hand back something other than a map; only a
            ;; map gets the client attached, mirroring canonical's second
            ;; ismap(first) guard.
            first-arg (if (u/ismap first-arg) (assoc first-arg "client" client) first-arg)]
        [(assoc args 0 first-arg) (assoc entry "ctx" first-arg)])
      [args entry])))

;; `argsmode` true means the subject returns `[args result]` rather than just
;; a result, so `match.args` can see what it did with its arguments. Clojure's
;; own data is immutable and a consumer's nodes are its own (struct/clojure
;; keeps java.util.LinkedHashMap / ArrayList), so returning them alongside the
;; result is the only channel there is. See `runsetflags-args`.
(defn- run-set-flags [runpack testspec flags testsubject & [argsmode]]
  (let [{:keys [spec subject provider clients name specversion]} runpack
        donull (if (contains? flags :null) (boolean (:null flags)) true)
        label (or (:name flags) (if (string/blank? name) "set" name))
        usesubject (or testsubject subject)]

    (when (nil? usesubject)
      (throw (omni-error (str "omni: no test subject for: " label))))

    (let [testspecmap (fixjson testspec donull)
          testset (get testspecmap "set")]

      (when-not (u/islist testset)
        (throw (omni-error (str "omni: test spec has no set: " label))))

      (when (<= 1 specversion)
        (checkset label testspec testset))

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

              [args withctx] (resolveargs entry provider (or client provider))]

          (try
            (let [outcome (entrysubject args)
                  callargs (if argsmode (vec (first outcome)) args)
                  rawres (if argsmode (second outcome) outcome)
                  res (fixjson rawres donull)
                  done (assoc withctx "res" res)]
              (checkresult label index done callargs res))
            (catch Throwable err
              (if (omni-error? err)
                (throw err)
                (handleerror label index withctx err)))))))))

;; What a runner returns for one named spec section.
(defn- make-runpack [spec subject provider clients name specversion]
  (let [runpack {:spec spec :subject subject :provider provider
                 :clients clients :name name :client provider :specversion specversion}]
    (assoc runpack
           :set (fn [setname] (get spec setname))
           :runsetflags (fn [testspec flags testsubject]
                          (run-set-flags runpack testspec flags testsubject))
           ;; Everything :runsetflags does, for a subject that returns
           ;; `[args result]`. Separate from :runsetflags rather than
           ;; replacing it, so no consumer breaks for a capability most
           ;; subjects do not need. omni-rust, -cpp, -ocaml, -elixir and
           ;; -haskell carry the same second entry point (#23, #25, #26,
           ;; #27, #28).
           :runsetflags-args (fn [testspec flags testsubject]
                               (run-set-flags runpack testspec flags testsubject true))
           :runset (fn [testspec testsubject]
                     (run-set-flags runpack testspec {} testsubject)))))

;; Make a runner for a spec file path (or spec value) and a provider.
(defn make-runner
  ([specref] (make-runner specref {}))
  ([specref provider]
   ;; Resolved once, right after the spec is loaded, so a bad version or an
   ;; unsupported capability fails fast - before any runner name is even
   ;; resolved, let alone any test run.
   (let [alltests (if (string? specref) (loadspec specref) specref)
         specversion (resolveversion alltests)]
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

          (make-runpack spec subject provider clients name specversion)))))))
