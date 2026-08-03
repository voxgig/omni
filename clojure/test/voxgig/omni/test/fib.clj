;; The system under test: a tiny Fibonacci library.
;;
;; Every omni port ships this same library, with the same behaviour and the
;; same error messages, and tests it with the same spec file
;; (spec/fib.json).

(ns voxgig.omni.test.fib
  (:require [voxgig.omni.util :as u]))

;; Validate a Fibonacci index. The spec matches on these messages. The
;; library raises a plain exception, never the runner's own error type.
(defn fibindex [val]
  (when-not (u/isnum val)
    (throw (RuntimeException. (str "fib: not a number: " (u/stringify val)))))

  (let [num (double val)]
    (when-not (== num (Math/rint num))
      (throw (RuntimeException. (str "fib: non-integer index: " (u/stringify val)))))

    (when (> 0 num)
      (throw (RuntimeException. (str "fib: negative index: " (u/stringify val)))))

    (long num)))

;; The nth Fibonacci number: fib(0)=0, fib(1)=1.
(defn fibnum [index]
  (if (zero? index)
    0
    (loop [step 1 prev 0 cur 1]
      (if (>= step index)
        cur
        (recur (inc step) cur (+ prev cur))))))

(defn fib [val] (double (fibnum (fibindex val))))

;; The first n Fibonacci numbers.
(defn fibseq [val]
  (vec (map (fn [index] (double (fibnum index))) (range (fibindex val)))))

;; The Fibonacci numbers from index start to index end, inclusive.
(defn fibrange [start end]
  (let [from (fibindex start)
        to (fibindex end)]
    (vec (map (fn [index] (double (fibnum index))) (range from (inc to))))))

;; A description of the nth Fibonacci number. `prev` is nil at index 0,
;; which exercises the runner's null handling.
(defn fibinfo [val]
  (let [index (fibindex val)
        num (fibnum index)]
    (array-map
     "n" (double index)
     "val" (double num)
     "even" (zero? (mod num 2))
     "prev" (if (zero? index) nil (double (fibnum (dec index))))
     "label" (str "fib(" (u/numstr index) ")=" (u/numstr num)))))
