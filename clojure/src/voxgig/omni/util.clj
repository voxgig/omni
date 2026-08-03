;; Omni internal JSON utilities.
;;
;; Self-contained by design: the omni runner must be able to test *any*
;; library, including libraries that provide these same operations.

(ns voxgig.omni.util
  (:require [clojure.string :as string]))

(def NULLMARK "__NULL__")     ;; Value is JSON null.
(def UNDEFMARK "__UNDEF__")   ;; Value is not present.
(def EXISTSMARK "__EXISTS__") ;; Value exists (not undefined).

;; Clojure has nil for null, so absence needs its own marker.
(def ABSENT ::absent)

(defn isabsent [val] (= ABSENT val))

(defn ismap [val] (map? val))

(defn islist [val] (vector? val))

(defn isnode [val] (or (ismap val) (islist val)))

;; A JSON number? Booleans are not numbers.
(defn isnum [val] (and (number? val) (not (boolean? val))))

(defn isstr [val] (string? val))

(defn isnone [val] (or (nil? val) (isabsent val)))

;; Deep copy a JSON value (Clojure values are immutable).
(defn clone [val] val)

;; Read a value by path. Returns ABSENT when any step is missing.
(defn getpath [val path]
  (reduce
   (fn [current part]
     (cond
       (islist current)
       (let [index (try (Integer/parseInt (str part)) (catch NumberFormatException _ nil))]
         (if (and index (<= 0 index) (< index (count current)))
           (nth current index)
           (reduced ABSENT)))

       (ismap current)
       (if (contains? current (str part))
         (get current (str part))
         (reduced ABSENT))

       :else (reduced ABSENT)))
   val
   path))

;; Depth-first walk: children first, then the containing node.
(defn walk
  ([val apply-fn] (walk val apply-fn []))
  ([val apply-fn path]
   (let [next (cond
                (islist val)
                (vec (map-indexed (fn [index entry] (walk entry apply-fn (conj path (str index))))
                                  val))

                (ismap val)
                (reduce-kv (fn [out key entry] (assoc out key (walk entry apply-fn (conj path key))))
                           (array-map)
                           val)

                :else val)]
     (apply-fn next path))))

;; Deep structural equality: numbers by value, bools never numbers.
(defn deepequal [a b]
  (cond
    (or (boolean? a) (boolean? b)) (and (boolean? a) (boolean? b) (= a b))
    (or (isnum a) (isnum b)) (and (isnum a) (isnum b) (== a b))
    (or (isabsent a) (isabsent b)) (and (isabsent a) (isabsent b))
    (or (nil? a) (nil? b)) (and (nil? a) (nil? b))

    (or (islist a) (islist b))
    (and (islist a) (islist b) (= (count a) (count b))
         (every? true? (map deepequal a b)))

    (or (ismap a) (ismap b))
    (and (ismap a) (ismap b) (= (count a) (count b))
         (every? (fn [[key entry]] (and (contains? b key) (deepequal entry (get b key)))) a))

    :else (= a b)))

;; Render a number the same way in every port: 5.0 prints as 5.
(defn numstr [val]
  (let [asdouble (double val)]
    (cond
      (or (Double/isNaN asdouble) (Double/isInfinite asdouble)) "null"
      (and (== asdouble (Math/rint asdouble)) (< (Math/abs asdouble) 9007199254740992.0))
      (str (long asdouble))
      :else (str asdouble))))

;; Render a string as a JSON string literal.
(defn quote-str [^String val]
  (let [out (StringBuilder. "\"")]
    (doseq [ch val]
      (cond
        (= \" ch) (.append out "\\\"")
        (= \\ ch) (.append out "\\\\")
        (= \newline ch) (.append out "\\n")
        (= \return ch) (.append out "\\r")
        (= \tab ch) (.append out "\\t")
        (< (int ch) 0x20) (.append out (format "\\u%04x" (int ch)))
        :else (.append out ch)))
    (.toString (.append out "\""))))

;; Compact JSON text with map keys sorted, identical in every port.
(defn jsonstr [val]
  (cond
    (isabsent val) "undefined"
    (nil? val) "null"
    (boolean? val) (if val "true" "false")
    (string? val) (quote-str val)
    (isnum val) (numstr val)
    (islist val) (str "[" (string/join "," (map jsonstr val)) "]")
    (ismap val) (str "{"
                     (string/join "," (map (fn [key] (str (quote-str (str key)) ":"
                                                          (jsonstr (get val key))))
                                           (sort (map str (keys val)))))
                     "}")
    :else (quote-str (str val))))

;; Strings verbatim, everything else as compact JSON.
(defn stringify [val]
  (if (string? val) val (jsonstr val)))

;; Render a path as a dotted string.
(defn pathify [path]
  (string/join "." (map str path)))
