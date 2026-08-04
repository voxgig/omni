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

;; The provider hosts the system under test. `shift` offsets the Fibonacci
;; index, so that a client-specific subject is observably different.
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
               (fibprovider (if (u/isnum shiftval) shiftval 0))))})

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
    (testcase "reports entry index and id" checkmessage)

    (println (str "\n" @PASSCOUNT " passed, " @FAILCOUNT " failed"))

    (System/exit (if (zero? @FAILCOUNT) 0 1))))
