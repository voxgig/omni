;; The omni JSON parser.
;;
;; The omni runner must be able to test *any* library, and must add no
;; third-party dependencies, so it carries its own JSON parsing rather than
;; borrowing clojure.data.json, cheshire or the system under test.
;;
;; Parses into native Clojure values: maps with string keys (insertion
;; ordered), vectors, strings, doubles, booleans and nil.

(ns voxgig.omni.json)

(defn- ws? [ch]
  (or (= \space ch) (= \tab ch) (= \newline ch) (= \return ch)))

(defn- skipws [^String text pos]
  (loop [at pos]
    (if (and (< at (.length text)) (ws? (.charAt text at)))
      (recur (inc at))
      at)))

(declare parse-value)

(defn- parse-word [^String text pos word value]
  (if (and (<= (+ pos (count word)) (.length text))
           (= word (subs text pos (+ pos (count word)))))
    [value (+ pos (count word))]
    (throw (ex-info (str "omni: bad JSON literal at " pos) {:pos pos}))))

(defn- parse-string [^String text pos]
  (when (or (>= pos (.length text)) (not= \" (.charAt text pos)))
    (throw (ex-info (str "omni: expected string at " pos) {:pos pos})))

  (loop [at (inc pos)
         out (StringBuilder.)]
    (when (>= at (.length text))
      (throw (ex-info "omni: unterminated JSON string" {:pos at})))

    (let [ch (.charAt text at)]
      (cond
        (= \" ch) [(.toString out) (inc at)]

        (not= \\ ch) (recur (inc at) (.append out ch))

        :else
        (let [escape (.charAt text (inc at))]
          (case escape
            \" (recur (+ at 2) (.append out \"))
            \\ (recur (+ at 2) (.append out \\))
            \/ (recur (+ at 2) (.append out \/))
            \b (recur (+ at 2) (.append out \backspace))
            \f (recur (+ at 2) (.append out \formfeed))
            \n (recur (+ at 2) (.append out \newline))
            \r (recur (+ at 2) (.append out \return))
            \t (recur (+ at 2) (.append out \tab))
            \u (recur (+ at 6)
                      (.append out (char (Integer/parseInt (subs text (+ at 2) (+ at 6)) 16))))
            (throw (ex-info (str "omni: bad JSON escape at " at) {:pos at}))))))))

(defn- numchar? [ch]
  (or (Character/isDigit ^char ch)
      (= \. ch) (= \e ch) (= \E ch) (= \- ch) (= \+ ch)))

(defn- parse-number [^String text pos]
  (let [start pos
        stop (loop [at (if (and (< pos (.length text))
                                (or (= \- (.charAt text pos)) (= \+ (.charAt text pos))))
                         (inc pos)
                         pos)]
               (if (and (< at (.length text)) (numchar? (.charAt text at)))
                 (recur (inc at))
                 at))
        span (subs text start stop)]
    (try
      [(Double/parseDouble span) stop]
      (catch NumberFormatException _
        (throw (ex-info (str "omni: bad JSON number [" span "] at " start) {:pos start}))))))

(defn- parse-map [^String text pos]
  (let [after (skipws text (inc pos))]
    (if (and (< after (.length text)) (= \} (.charAt text after)))
      [(array-map) (inc after)]
      (loop [at after
             out (array-map)]
        (let [at (skipws text at)
              [key keypos] (parse-string text at)
              colon (skipws text keypos)]

          (when (or (>= colon (.length text)) (not= \: (.charAt text colon)))
            (throw (ex-info (str "omni: expected ':' at " colon) {:pos colon})))

          (let [[value valpos] (parse-value text (skipws text (inc colon)))
                out (assoc out key value)
                next (skipws text valpos)]

            (when (>= next (.length text))
              (throw (ex-info "omni: unterminated JSON object" {:pos next})))

            (cond
              (= \, (.charAt text next)) (recur (inc next) out)
              (= \} (.charAt text next)) [out (inc next)]
              :else (throw (ex-info (str "omni: expected ',' or '}' at " next) {:pos next})))))))))

(defn- parse-list [^String text pos]
  (let [after (skipws text (inc pos))]
    (if (and (< after (.length text)) (= \] (.charAt text after)))
      [[] (inc after)]
      (loop [at after
             out []]
        (let [[value valpos] (parse-value text (skipws text at))
              out (conj out value)
              next (skipws text valpos)]

          (when (>= next (.length text))
            (throw (ex-info "omni: unterminated JSON array" {:pos next})))

          (cond
            (= \, (.charAt text next)) (recur (inc next) out)
            (= \] (.charAt text next)) [out (inc next)]
            :else (throw (ex-info (str "omni: expected ',' or ']' at " next) {:pos next}))))))))

(defn- parse-value [^String text pos]
  (when (>= pos (.length text))
    (throw (ex-info "omni: unexpected end of JSON" {:pos pos})))

  (let [ch (.charAt text pos)]
    (case ch
      \{ (parse-map text pos)
      \[ (parse-list text pos)
      \" (parse-string text pos)
      \t (parse-word text pos "true" true)
      \f (parse-word text pos "false" false)
      \n (parse-word text pos "null" nil)
      (parse-number text pos))))

(defn parse
  "Parse JSON text into native Clojure values."
  [^String text]
  (let [[value pos] (parse-value text (skipws text 0))
        rest (skipws text pos)]
    (when (< rest (.length text))
      (throw (ex-info (str "omni: trailing JSON content at " rest) {:pos rest})))
    value))
