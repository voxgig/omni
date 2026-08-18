;; RUN: clojure -M -m voxgig.omni.test.main
;; RUN-SOME: clojure -M -m voxgig.omni.test.main basic
;;
;; The Fibonacci conformance suite: every omni port runs this same set of
;; groups, from the same spec/fib.json, against the same fib library.
;;
;; No third-party test framework: a failing omni check throws, so
;; clojure.test reports it as an error. This harness keeps `make test`
;; dependency-free.

(ns voxgig.omni.test.main
  (:require [clojure.string :as string]
            [voxgig.omni.runner :as runner]
            [voxgig.omni.test.fib :as fib]
            [voxgig.omni.util :as u])
  (:import [java.io File])
  (:gen-class))

(def ONLY (atom nil))
(def PASSCOUNT (atom 0))
(def FAILCOUNT (atom 0))

;; Find the shared spec directory by walking up from the working directory.
(defn specfile [name]
  (loop [dir (File. (System/getProperty "user.dir"))
         step 0]
    (if (or (nil? dir) (<= 8 step))
      (throw (runner/omni-error (str "omni: spec not found: " name)))
      (let [cand (File. (File. dir "spec") ^String name)]
        (if (.exists cand)
          (.getAbsolutePath cand)
          (recur (.getParentFile dir) (inc step)))))))

(defn FIB [args] (fib/fib (first args)))
(defn FIBSEQ [args] (fib/fibseq (first args)))
(defn FIBRANGE [args] (fib/fibrange (first args) (second args)))
(defn FIBINFO [args] (fib/fibinfo (first args)))

;; The context-group subject: reports what the runner delivered - the
;; contextify mark and the attached client - as plain data, so the spec can
;; pin both with an ordinary `out` comparison.
(defn FIBCTX [args]
  (let [ctx (first args)]
    (array-map "n" (get ctx "n")
               "val" (fib/fib (get ctx "n"))
               "mark" (get ctx "mark")
               "hasclient" (some? (get ctx "client")))))

;; The provider hosts the system under test. `shift` offsets the Fibonacci
;; index, so that a client-specific subject is observably different.
;; `contextify` marks the map, so the context group can prove the hook ran.
(defn fibprovider [shift]
  {:subject (fn [name]
              (case name
                "fib" (fn [args]
                        (let [val (first args)]
                          (fib/fib (if (u/isnum val) (+ val shift) val))))
                "fibseq" FIBSEQ
                "fibrange" FIBRANGE
                "fibinfo" FIBINFO
                nil))
   :client (fn [options]
             (let [shiftval (get options "shift")]
               (fibprovider (if (u/isnum shiftval) shiftval 0))))
   :contextify (fn [val] (assoc val "mark" "CTX"))})

(defn testcase [name body]
  (when (or (nil? @ONLY) (= @ONLY name))
    (try
      (body)
      (swap! PASSCOUNT inc)
      (println (str "ok   - " name))
      (catch Throwable err
        (swap! FAILCOUNT inc)
        (println (str "FAIL - " name))
        (println (runner/errmessage err))))))

;; The runner must fail when the subject is wrong - otherwise a green suite
;; means nothing.
(def BADSPEC
  {"fib"
   {"wrongout" {"set" [{"in" 5.0 "out" 5.0} {"in" 6.0 "out" 999.0}]}
    "wrongerr" {"set" [{"in" 1.0 "err" "never happens"}]}
    "wrongmatch" {"set" [{"in" 6.0 "match" {"out" 999.0}}]}
    "missing" {"set" [{"in" 6.0 "match" {"out" {"nope" "__EXISTS__"}}}]}
    ;; A concrete match leaf against a missing key must fail, not
    ;; substring-match the text "undefined".
    "matchabsent" {"set" [{"in" 6.0 "match" {"out" {"nope" "fine"}}}]}
    ;; __UNDEF__ (absent) must not be satisfied by a present null.
    "undefonnull" {"set" [{"in" 0.0 "match" {"out" {"prev" "__UNDEF__"}}}]}
    ;; __NULL__ (present null) must not be satisfied by an absent key.
    "nullonabsent" {"set" [{"in" 6.0 "match" {"out" {"nope" "__NULL__"}}}]}
    ;; An empty-string want is a substring of everything, not a wildcard.
    "emptystr" {"set" [{"in" 6.0 "match" {"out" {"label" ""}}}]}}})

(defn expectfail [setname subject]
  (let [bad ((runner/make-runner BADSPEC) "fib")]
    (try
      ((:runset bad) ((:set bad) setname) subject)
      (throw (IllegalStateException. (str "omni: expected a failure for set: " setname)))
      (catch clojure.lang.ExceptionInfo err
        (when-not (runner/omni-error? err)
          (throw err))))))

(defn checkmessage []
  (let [spec {"fib" {"g" {"set" [{"in" 1.0 "out" 1.0}
                                 {"id" "x#2" "in" 2.0 "out" 42.0}]}}}
        bad ((runner/make-runner spec) "fib")]
    (try
      ((:runset bad) ((:set bad) "g") FIB)
      (throw (IllegalStateException. "omni: expected a failure"))
      (catch clojure.lang.ExceptionInfo err
        (let [msg (ex-message err)]
          (doseq [want ["fib[1] (x#2)" "expected: 42" "actual:   1"]]
            (when-not (string/includes? msg want)
              (throw (IllegalStateException. (str "omni: message missing [" want "]: " msg))))))))))

;; Assert that `make-runner` itself refuses the spec - version resolution
;; runs eagerly, right after the spec loads, before any group is touched.
(defn expectloadfail [spec wantsub]
  (try
    (runner/make-runner spec)
    (throw (IllegalStateException. (str "omni: expected make-runner to fail: " wantsub)))
    (catch clojure.lang.ExceptionInfo err
      (when-not (runner/omni-error? err)
        (throw err))
      (let [msg (ex-message err)]
        (when-not (string/includes? msg wantsub)
          (throw (IllegalStateException. (str "omni: message missing [" wantsub "]: " msg))))))))

;; Assert that running the named group of `spec` fails, with a message
;; containing wantsub.
(defn expectsetfail [spec setname subject wantsub]
  (let [bad ((runner/make-runner spec) "fib")]
    (try
      ((:runset bad) ((:set bad) setname) subject)
      (throw (IllegalStateException. (str "omni: expected a failure for set: " setname)))
      (catch clojure.lang.ExceptionInfo err
        (when-not (runner/omni-error? err)
          (throw err))
        (let [msg (ex-message err)]
          (when-not (string/includes? msg wantsub)
            (throw (IllegalStateException. (str "omni: message missing [" wantsub "]: " msg)))))))))

;; A present-but-null OMNI block is malformed; only a genuinely absent OMNI
;; key is legacy. A port that tests definedness rather than presence
;; silently skips strict mode here, so both cases are pinned.
(defn checknullomni []
  (expectloadfail {"OMNI" nil "fib" {"g" {"set" [{"in" 1.0 "out" 1.0}]}}}
                   "malformed OMNI")
  (expectloadfail {"OMNI" {"version" 1.0 "requires" nil} "fib" {"g" {"set" [{"in" 1.0 "out" 1.0}]}}}
                   "malformed OMNI requires list")
  (runner/make-runner {"fib" {"g" {"set" [{"in" 1.0 "out" 1.0}]}}}))

(defn checkemptyset []
  (let [spec {"OMNI" {"version" 1.0}
              "fib" {"g" {"set" []}
                     "h" {"set" [] "empty" true}}}]
    (expectsetfail spec "g" FIB "empty test set")
    (let [ok ((runner/make-runner spec) "fib")]
      ((:runset ok) ((:set ok) "h") FIB))))

(defn -main [& args]
  (when (seq args)
    (reset! ONLY (first args)))

  (let [R ((runner/make-runner (specfile "fib.json") (fibprovider 0)) "fib")
        spec-set (:set R)
        runset (:runset R)
        runsetflags (:runsetflags R)]

    (testcase "basic" #(runset (spec-set "basic") FIB))
    (testcase "seq" #(runset (spec-set "seq") FIBSEQ))
    (testcase "range" #(runset (spec-set "range") FIBRANGE))
    (testcase "info" #(runset (spec-set "info") FIBINFO))
    (testcase "nulls" #(runsetflags (spec-set "nulls") {:null false} FIBINFO))
    (testcase "error" #(runset (spec-set "error") FIB))
    (testcase "match" #(runset (spec-set "match") FIB))
    (testcase "matchinfo" #(runset (spec-set "matchinfo") FIBINFO))
    (testcase "client" #(runset (spec-set "client") FIB))
    (testcase "context" #(runset (spec-set "context") FIBCTX))

    (testcase "detects wrong result" #(expectfail "wrongout" FIB))
    (testcase "detects missing error" #(expectfail "wrongerr" FIB))
    (testcase "detects failed match" #(expectfail "wrongmatch" FIB))
    (testcase "detects absent key" #(expectfail "missing" FIBINFO))
    (testcase "a concrete match leaf does not match a missing key"
              #(expectfail "matchabsent" FIBINFO))
    (testcase "__UNDEF__ does not match a present null"
              #(expectfail "undefonnull" FIBINFO))
    (testcase "__NULL__ does not match an absent key"
              #(expectfail "nullonabsent" FIBINFO))
    (testcase "an empty-string match leaf is not a wildcard"
              #(expectfail "emptystr" FIBINFO))

    (testcase "rejects an unsupported spec version"
              #(expectloadfail {"OMNI" {"version" 99.0} "fib" {"g" {"set" []}}}
                                "unsupported spec version"))
    (testcase "rejects an unknown required capability"
              #(expectloadfail {"OMNI" {"version" 1.0 "requires" ["nosuchfeature"]}
                                 "fib" {"g" {"set" []}}}
                                "unsupported capability"))
    (testcase "rejects a malformed version block"
              #(expectloadfail {"OMNI" {"version" "one"} "fib" {"g" {"set" []}}}
                                "malformed OMNI"))
    (testcase "rejects a null OMNI block, but accepts an absent one" checknullomni)
    (testcase "strict: an unknown entry field fails instead of passing vacuously"
              #(expectsetfail {"OMNI" {"version" 1.0}
                                "fib" {"g" {"set" [{"in" 6.0 "matches" {"out" 999.0}}]}}}
                               "g" FIBINFO "unknown entry field: matches"))
    (testcase "strict: more than one of in, args, ctx fails"
              #(expectsetfail {"OMNI" {"version" 1.0}
                                "fib" {"g" {"set" [{"in" 5.0 "args" [5.0] "out" 5.0}]}}}
                               "g" FIB "more than one of in, args, ctx"))
    (testcase "strict: err together with out fails"
              #(expectsetfail {"OMNI" {"version" 1.0}
                                "fib" {"g" {"set" [{"in" -1.0 "err" true "out" 5.0}]}}}
                               "g" FIB "both err and out"))
    (testcase "strict: a null id fails even under null-normalisation"
              #(expectsetfail {"OMNI" {"version" 1.0}
                                "fib" {"g" {"set" [{"in" 1.0 "out" 1.0 "id" nil}]}}}
                               "g" FIB "entry id is not a string"))
    (testcase "strict: an empty set fails unless marked empty" checkemptyset)
    (testcase "a legacy spec (no OMNI block) stays lenient"
              #(let [spec {"fib" {"g" {"set" [{"in" 6.0 "matches" {"out" 999.0} "out" 8.0}]}}}
                     ok ((runner/make-runner spec) "fib")]
                 ((:runset ok) ((:set ok) "g") FIB)))

    (testcase "reports entry index and id" checkmessage)

    (println (str "\n" @PASSCOUNT " passed, " @FAILCOUNT " failed"))

    (System/exit (if (zero? @FAILCOUNT) 0 1))))
