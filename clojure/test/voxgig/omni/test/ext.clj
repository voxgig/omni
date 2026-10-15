;; RUN: clojure -M:test -m voxgig.omni.test.main
;;
;; The capability suite: spec/ext.json requires ctxargs, fn and wait, and
;; runs here beside the runner flag `all`. voxgig.omni.test.main runs these
;; cases after the Fibonacci suite.

(ns voxgig.omni.test.ext
  (:require [voxgig.omni.runner :as runner]
            [voxgig.omni.test.fib :as fib]))

(defn- FIB [args] (fib/fib (first args)))
(defn- FIBSEQ [args] (fib/fibseq (first args)))
(defn- FIBRANGE [args] (fib/fibrange (first args) (second args)))
(defn- FIBINFO [args] (fib/fibinfo (first args)))

(defn- fibprovider []
  (let [subjects {"fib" FIB "fibseq" FIBSEQ "fibrange" FIBRANGE "fibinfo" FIBINFO}]
    {:subject (fn [name] (get subjects name))
     :contextify (fn [val] (assoc val "mark" "CTX"))}))

;; The ctxargs subject: the context comes first, and must arrive
;; contextified with its client attached.
(defn- FIBSHIFTED [[ctx start end]]
  (when-not (and (= "CTX" (get ctx "mark")) (some? (get ctx "client")))
    (throw (RuntimeException. "fib: context not delivered")))
  (let [shift (get ctx "shift")]
    (fib/fibrange (+ start shift) (+ end shift))))

(defn- extrunner [spec]
  ((runner/make-runner spec (fibprovider)) "fib"))

(defn- v1 [requires entries]
  {"OMNI" {"version" 1.0 "requires" requires} "fib" {"g" {"set" entries}}})

(defn- g [R] ((:set R) "g"))

(defn- refuses [run pattern]
  (let [err (try (run) nil (catch Throwable err err))]
    (when-not (and (some? err) (runner/omni-error? err) (re-find pattern (ex-message err)))
      (throw (IllegalStateException.
              (str "omni: expected a refusal matching " pattern ", got: "
                   (if (some? err) (ex-message err) "no error")))))))

(defn- capabilities []
  (doseq [cap ["ctxargs" "fn" "wait"]]
    (when-not (some #{cap} runner/CAPABILITIES)
      (throw (IllegalStateException. (str "omni: missing capability: " cap))))))

(defn- extgroup [specfile group subject]
  (let [R (extrunner (specfile "ext.json"))]
    ((:runset R) ((:set R) group) subject)))

(defn- stalewait []
  (let [R (extrunner (v1 ["wait"] [{"in" 5.0 "out" 5.0 "wait" {"cause" "gone#1"}}]))]
    (refuses #((:runset R) (g R) FIB) #"\[0\]: stale wait: gone#1")))

(defn- waitflagholds []
  (let [R (extrunner (v1 [] [{"id" "a" "in" 6.0 "out" 9.0} {"in" 7.0 "out" 13.0}]))]
    ((:runsetflags R) (g R) {:wait {"a" {"cause" "flag#1"}}} FIB)))

(defn- waitflagstale []
  (let [R (extrunner (v1 [] [{"id" "a" "in" 6.0 "out" 8.0}]))]
    (refuses #((:runsetflags R) (g R) {:wait {"a" {"cause" "flag#1"}}} FIB)
             #"stale wait: flag#1")))

(defn- waitflagnoentry []
  (let [R (extrunner (v1 [] [{"id" "a" "in" 6.0 "out" 8.0}]))]
    (refuses #((:runsetflags R) (g R) {:wait {"zz" {"cause" "c"}}} FIB)
             #"wait names no entry: zz")))

(defn- waitnocause []
  (let [R (extrunner (v1 ["wait"] [{"in" 6.0 "out" 9.0 "wait" {}}]))]
    (refuses #((:runset R) (g R) FIB) #"entry wait has no cause")))

(defn- unknownunlessrequired []
  (let [W (extrunner (v1 [] [{"in" 6.0 "out" 9.0 "wait" {"cause" "c"}}]))
        F (extrunner (v1 [] [{"fn" "fib" "in" 6.0 "out" 8.0}]))]
    (refuses #((:runset W) (g W) FIB) #"unknown entry field: wait")
    (refuses #((:runset F) (g F) FIB) #"unknown entry field: fn")))

(defn- unknownfn []
  (let [R (extrunner (v1 ["fn"] [{"fn" "nope" "in" 6.0 "out" 8.0}]))]
    (refuses #((:runset R) (g R) FIB) #"unknown fn: nope")))

(defn- ctxwithargs []
  (let [N (extrunner (v1 [] [{"ctx" {"shift" 0.0} "args" [0.0 1.0] "out" [0.0 1.0]}]))
        I (extrunner (v1 ["ctxargs"] [{"in" 1.0 "ctx" {"shift" 0.0} "out" [0.0]}]))]
    (refuses #((:runset N) (g N) FIBSHIFTED) #"more than one of in, args, ctx")
    (refuses #((:runset I) (g I) FIBSHIFTED) #"entry has in beside args or ctx")))

(defn- legacyignores []
  (let [R (extrunner {"fib" {"g" {"set" [{"in" 6.0 "out" 8.0 "fn" "nope" "wait" {"cause" "c"}}]}}})]
    ((:runset R) (g R) FIB)))

(defn- allfailures []
  (let [R (extrunner (v1 [] [{"in" 5.0 "out" 6.0} {"in" 6.0 "out" 8.0} {"in" 7.0 "out" 14.0}]))]
    (refuses #((:runsetflags R) (g R) {:all true} FIB)
             #"(?s)^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch")
    (refuses #((:runset R) (g R) FIB) #"^omni: fib\[0\]: result mismatch")))

(defn- raisinghook []
  (let [boom (fn [_] (throw (RuntimeException. "contextify boom")))
        provider {:subject (fn [_] FIB) :contextify boom}
        run (fn [spec] ((runner/make-runner spec provider) "fib"))
        E (run (v1 [] [{"ctx" {"n" 6.0} "err" "contextify boom"}]))
        U (run (v1 [] [{"ctx" {"n" 6.0} "out" 8.0}]))
        W (run (v1 ["wait"] [{"ctx" {"n" 6.0} "out" 8.0 "wait" {"cause" "hook#1"}}]))
        F ((runner/make-runner
            (v1 ["fn"] [{"fn" "boom" "in" 6.0 "err" "subject boom"}])
            {:subject (fn [name]
                        (when (= "boom" name)
                          (throw (RuntimeException. "subject boom")))
                        FIB)})
           "fib")]
    ((:runset E) (g E) FIB)
    (refuses #((:runset U) (g U) FIB) #"\[0\]: unexpected error\n\s+actual:\s+contextify boom")
    ((:runset W) (g W) FIB)
    ((:runset F) (g F) FIB)))

(defn- prestartheld []
  (let [provider {:subject (fn [name]
                             (cond
                               (= "boom" name) (throw (RuntimeException. "subject boom"))
                               (= "fib" name) FIB
                               :else nil))}
        run (fn [spec] ((runner/make-runner spec provider) "fib"))
        H (run (v1 ["fn" "wait"] [{"fn" "boom" "in" 6.0 "out" 8.0 "wait" {"cause" "hook#2"}}]))
        S (run (v1 ["fn" "wait"] [{"fn" "boom" "in" 6.0 "err" "subject boom"
                                   "wait" {"cause" "hook#3"}}]))]
    ((:runset H) (g H) FIB)
    (refuses #((:runset S) (g S) FIB) #"\[0\]: stale wait: hook#3")))

;; A nil subject is how runset is given none.
(defn- fnnodefault []
  (let [provider {:subject (fn [name] (when (= "fibx" name) FIB))}
        run (fn [spec] ((runner/make-runner spec provider) "fib"))
        R (run (v1 ["fn"] [{"fn" "fibx" "in" 6.0 "out" 8.0}]))
        N (run (v1 ["fn"] [{"fn" "fibx" "in" 6.0 "out" 8.0} {"in" 6.0 "out" 8.0}]))
        L (run (v1 [] [{"in" 6.0 "out" 8.0}]))]
    ((:runset R) (g R) nil)
    (refuses #((:runset N) (g N) nil) #"^omni: no test subject for: fib$")
    (refuses #((:runset L) (g L) nil) #"^omni: no test subject for: fib$")))

(defn- ownwaitid []
  (let [R (extrunner (v1 [] [{"id" "constructor" "in" 6.0 "out" 8.0}
                             {"id" "toString" "in" 7.0 "out" 13.0}]))]
    ((:runset R) (g R) FIB)
    ((:runsetflags R) (g R) {:wait {}} FIB)))

;; Each case as [name body], for the main harness to run and count.
(defn cases [specfile]
  [["ext: capabilities" capabilities]
   ["ext: ctxargs" #(extgroup specfile "ctxargs" FIBSHIFTED)]
   ["ext: fn" #(extgroup specfile "fn" FIB)]
   ["ext: wait" #(extgroup specfile "wait" FIB)]
   ["ext: a waiting entry that passes fails the set" stalewait]
   ["ext: the wait flag holds an entry by id" waitflagholds]
   ["ext: the wait flag fails when its entry passes" waitflagstale]
   ["ext: the wait flag must name an entry" waitflagnoentry]
   ["ext: a wait needs a cause" waitnocause]
   ["ext: wait and fn are unknown fields unless required" unknownunlessrequired]
   ["ext: an unknown fn is a spec error" unknownfn]
   ["ext: ctx with args needs ctxargs, and never takes in" ctxwithargs]
   ["ext: a legacy spec ignores fn and wait" legacyignores]
   ["ext: a raising hook is the entry's error, not the set's" raisinghook]
   ["ext: a waiting entry holds a hook's error raised before the subject starts" prestartheld]
   ["ext: fn needs no default subject, but an entry without fn does" fnnodefault]
   ["ext: a wait is found by an id the entry owns, never an inherited one" ownwaitid]
   ["ext: all reports every failure at once" allfailures]])
