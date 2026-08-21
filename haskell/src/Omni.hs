-- | Omni: the shared multi-language test runner (Haskell port).
--
-- A test spec is plain JSON. The same spec file drives the same tests in
-- every language that ships an omni port.
--
-- Port of the canonical TypeScript implementation
-- (typescript/src/Runner.ts). Behaviour must match, case for case.
--
-- Self-contained by design: the runner carries its own JSON value model,
-- parser and regex engine, so that it can test *any* library - including
-- one that provides those same operations - and adds no dependencies
-- beyond base.

module Omni
  ( Json (..),
    Flags (..),
    Provider (..),
    RunPack (..),
    Subject,
    SubjectArgs,
    OmniError (..),
    nullmark,
    undefmark,
    existsmark,
    specversion,
    capabilities,
    defaultFlags,
    nonullFlags,
    emptyProvider,
    ismap,
    islist,
    isnode,
    isabsent,
    isnull,
    isnone,
    isnum,
    isstr,
    asnum,
    asstr,
    aslist,
    asmap,
    jget,
    jhas,
    jset,
    parse,
    loadspec,
    resolvespec,
    clone,
    deepequal,
    getpath,
    walk,
    jsonstr,
    stringify,
    numstr,
    pathify,
    fixjson,
    errify,
    errmessage,
    matchval,
    nullmodifier,
    regexFind,
    makeRunner,
    makeRunnerSpec,
  )
where

import Control.Exception (Exception, SomeException, displayException, fromException, throwIO, try)
import Data.Char (isAlphaNum, isDigit, isSpace, toLower)
import Data.List (isInfixOf, isPrefixOf, sortBy)
import Data.Maybe (fromMaybe, isJust)
import Numeric (showHex)
import Text.Printf (printf)

-- ---- the JSON value model -------------------------------------------

-- | A JSON value. 'Absent' is the marker for "no value at all", as
-- distinct from 'Null'.
data Json
  = Absent
  | Null
  | Bool Bool
  | Num Double
  | Str String
  | JList [Json]
  | JMap [(String, Json)]
  deriving (Show)

nullmark :: String
nullmark = "__NULL__" -- Value is JSON null.

undefmark :: String
undefmark = "__UNDEF__" -- Value is not present.

existsmark :: String
existsmark = "__EXISTS__" -- Value exists (not undefined).

ismap :: Json -> Bool
ismap (JMap _) = True
ismap _ = False

islist :: Json -> Bool
islist (JList _) = True
islist _ = False

isnode :: Json -> Bool
isnode value = ismap value || islist value

isabsent :: Json -> Bool
isabsent Absent = True
isabsent _ = False

isnull :: Json -> Bool
isnull Null = True
isnull _ = False

isnone :: Json -> Bool
isnone value = isabsent value || isnull value

isnum :: Json -> Bool
isnum (Num _) = True
isnum _ = False

isstr :: Json -> Bool
isstr (Str _) = True
isstr _ = False

asnum :: Json -> Maybe Double
asnum (Num value) = Just value
asnum _ = Nothing

asstr :: Json -> Maybe String
asstr (Str value) = Just value
asstr _ = Nothing

aslist :: Json -> Maybe [Json]
aslist (JList value) = Just value
aslist _ = Nothing

asmap :: Json -> Maybe [(String, Json)]
asmap (JMap value) = Just value
asmap _ = Nothing

-- | Read a map entry. Returns 'Absent' when missing.
jget :: Json -> String -> Json
jget (JMap entries) key = fromMaybe Absent (lookup key entries)
jget _ _ = Absent

-- | Is a map key present at all (even with a null value)?
jhas :: Json -> String -> Bool
jhas (JMap entries) key = isJust (lookup key entries)
jhas _ _ = False

-- | A copy of a map with one entry set (no-op for non-maps).
jset :: Json -> String -> Json -> Json
jset (JMap entries) key entry =
  if isJust (lookup key entries)
    then JMap (map (\(k, e) -> if k == key then (k, entry) else (k, e)) entries)
    else JMap (entries ++ [(key, entry)])
jset other _ _ = other

-- ---- errors ----------------------------------------------------------

-- | A test failure (or a malformed spec). Distinct from an exception
-- thrown by the subject under test, which is a candidate for an @err@
-- expectation.
newtype OmniError = OmniError String

instance Show OmniError where
  show (OmniError message) = message

instance Exception OmniError

-- ---- number and string rendering ------------------------------------

-- | Render a number the same way in every port: 5.0 prints as 5.
numstr :: Double -> String
numstr value
  | isNaN value || isInfinite value = "null"
  | value == fromIntegral rounded && abs value < 9007199254740992.0 = show rounded
  | otherwise = trimzeros (printf "%.17g" value)
  where
    rounded = truncate value :: Integer

    trimzeros text =
      if '.' `elem` text && 'e' `notElem` text && 'E' `notElem` text
        then reverse (dropdot (dropWhile (== '0') (reverse text)))
        else text

    dropdot ('.' : rest) = rest
    dropdot rest = rest

-- | Render a string as a JSON string literal.
quote :: String -> String
quote value = "\"" ++ concatMap escape value ++ "\""
  where
    escape ch = case ch of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ ->
        if fromEnum ch < 0x20
          then "\\u" ++ pad (showHex (fromEnum ch) "")
          else [ch]

    pad text = replicate (4 - length text) '0' ++ text

-- | Compact JSON text with map keys sorted, identical in every port.
jsonstr :: Json -> String
jsonstr Absent = "undefined"
jsonstr Null = "null"
jsonstr (Bool flag) = if flag then "true" else "false"
jsonstr (Num value) = numstr value
jsonstr (Str text) = quote text
jsonstr (JList entries) = "[" ++ joinwith "," (map jsonstr entries) ++ "]"
jsonstr (JMap entries) =
  "{" ++ joinwith "," (map render sorted) ++ "}"
  where
    sorted = sortBy (\(a, _) (b, _) -> compare a b) entries
    render (key, entry) = quote key ++ ":" ++ jsonstr entry

-- | Strings verbatim, everything else as compact JSON.
stringify :: Json -> String
stringify (Str text) = text
stringify other = jsonstr other

joinwith :: String -> [String] -> String
joinwith _ [] = ""
joinwith _ [single] = single
joinwith sep (head' : rest) = head' ++ sep ++ joinwith sep rest

-- | Render a path as a dotted string.
pathify :: [String] -> String
pathify = joinwith "."

-- ---- json parser -----------------------------------------------------

-- | Parse JSON text into the omni value model.
parse :: String -> Either String Json
parse text = case parseValue (skipws text) of
  Left message -> Left message
  Right (value, rest) ->
    if null (skipws rest)
      then Right value
      else Left "omni: trailing JSON content"

skipws :: String -> String
skipws = dropWhile isSpace

parseValue :: String -> Either String (Json, String)
parseValue [] = Left "omni: unexpected end of JSON"
parseValue text@(ch : rest)
  | '{' == ch = parseMap (skipws rest) []
  | '[' == ch = parseList (skipws rest) []
  | '"' == ch = fmap (\(value, more) -> (Str value, more)) (parseString rest "")
  | "true" `isPrefixOf` text = Right (Bool True, drop 4 text)
  | "false" `isPrefixOf` text = Right (Bool False, drop 5 text)
  | "null" `isPrefixOf` text = Right (Null, drop 4 text)
  | otherwise = parseNumber text

parseMap :: String -> [(String, Json)] -> Either String (Json, String)
parseMap ('}' : rest) entries = Right (JMap (reverse entries), rest)
parseMap text entries = parseMapPair text entries

-- A comma must be followed by another pair: no trailing commas.
parseMapPair :: String -> [(String, Json)] -> Either String (Json, String)
parseMapPair text entries = do
  (key, afterkey) <- case skipws text of
    '"' : more -> parseString more ""
    _ -> Left "omni: expected string key"

  aftercolon <- case skipws afterkey of
    ':' : more -> Right more
    _ -> Left "omni: expected ':'"

  (value, aftervalue) <- parseValue (skipws aftercolon)

  -- A duplicate key overrides the earlier value (last wins), as in the
  -- canonical implementation.
  let entries' =
        if isJust (lookup key entries)
          then map (\(k, e) -> if k == key then (k, value) else (k, e)) entries
          else (key, value) : entries

  case skipws aftervalue of
    ',' : more -> parseMapPair (skipws more) entries'
    '}' : more -> Right (JMap (reverse entries'), more)
    _ -> Left "omni: expected ',' or '}'"

parseList :: String -> [Json] -> Either String (Json, String)
parseList (']' : rest) entries = Right (JList (reverse entries), rest)
parseList text entries = parseListItem text entries

-- A comma must be followed by another element: no trailing commas.
parseListItem :: String -> [Json] -> Either String (Json, String)
parseListItem text entries = do
  (value, aftervalue) <- parseValue (skipws text)

  case skipws aftervalue of
    ',' : more -> parseListItem (skipws more) (value : entries)
    ']' : more -> Right (JList (reverse (value : entries)), more)
    _ -> Left "omni: expected ',' or ']'"

parseString :: String -> String -> Either String (String, String)
parseString [] _ = Left "omni: unterminated JSON string"
parseString ('"' : rest) out = Right (reverse out, rest)
parseString ('\\' : escape : rest) out = case escape of
  '"' -> parseString rest ('"' : out)
  '\\' -> parseString rest ('\\' : out)
  '/' -> parseString rest ('/' : out)
  'b' -> parseString rest ('\b' : out)
  'f' -> parseString rest ('\f' : out)
  'n' -> parseString rest ('\n' : out)
  'r' -> parseString rest ('\r' : out)
  't' -> parseString rest ('\t' : out)
  'u' ->
    -- Exactly four hex digits: anything else is a parse error, not
    -- garbage arithmetic on arbitrary characters.
    let (hex, more) = splitAt 4 rest
     in if 4 == length hex && all ishex hex
          then parseString more (toEnum (readhex hex) : out)
          else Left "omni: bad JSON unicode escape"
  _ -> Left "omni: bad JSON escape"
  where
    ishex ch = isDigit ch || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
    readhex = foldl (\acc ch -> acc * 16 + digit ch) 0
    digit ch
      | isDigit ch = fromEnum ch - fromEnum '0'
      | ch >= 'a' && ch <= 'f' = fromEnum ch - fromEnum 'a' + 10
      | otherwise = fromEnum ch - fromEnum 'A' + 10
parseString (ch : rest) out = parseString rest (ch : out)

parseNumber :: String -> Either String (Json, String)
parseNumber text =
  let (sign, afterSign) = span (\ch -> '-' == ch || '+' == ch) text
      (digits, rest) = span (\ch -> isDigit ch || '.' == ch || 'e' == ch || 'E' == ch || '-' == ch || '+' == ch) afterSign
      span' = sign ++ digits
   in if null digits
        then Left "omni: bad JSON number"
        else case reads (fixup span') :: [(Double, String)] of
          [(value, "")] -> Right (Num value, rest)
          _ -> Left ("omni: bad JSON number [" ++ span' ++ "]")
  where
    -- Haskell's `reads` wants a digit before the point and no leading '+'.
    fixup ('+' : more) = fixup more
    fixup ('-' : '.' : more) = "-0." ++ more
    fixup ('.' : more) = "0." ++ more
    fixup other = other

-- | Load a spec: a path to a JSON file.
loadspec :: String -> IO Json
loadspec path = do
  text <- readFile path
  case parse text of
    Right value -> pure value
    Left message -> throwIO (OmniError ("omni: cannot parse spec: " ++ path ++ ": " ++ message))

-- ---- util ------------------------------------------------------------

-- | Deep copy a JSON value (the value model is immutable).
clone :: Json -> Json
clone = id

-- | Read a value by path. Returns 'Absent' when any step is missing.
getpath :: Json -> [String] -> Json
getpath value [] = value
getpath value (part : rest) =
  let next = case value of
        JList entries -> case readIndex part of
          Just index | index >= 0 && index < length entries -> entries !! index
          _ -> Absent
        JMap _ -> jget value part
        _ -> Absent
   in if isabsent next then Absent else getpath next rest
  where
    readIndex text = case reads text :: [(Int, String)] of
      [(index, "")] -> Just index
      _ -> Nothing

-- | Depth-first walk: children first, then the containing node.
walk :: Json -> (Json -> [String] -> Json) -> [String] -> Json
walk value apply path = apply next path
  where
    next = case value of
      JList entries ->
        JList (zipWith (\index entry -> walk entry apply (path ++ [show index])) [0 :: Int ..] entries)
      JMap entries -> JMap (map (\(key, entry) -> (key, walk entry apply (path ++ [key]))) entries)
      other -> other

-- | Deep structural equality: numbers by value, bools never numbers.
deepequal :: Json -> Json -> Bool
deepequal Absent Absent = True
deepequal Null Null = True
deepequal (Bool x) (Bool y) = x == y
deepequal (Num x) (Num y) = x == y || (isNaN x && isNaN y)
deepequal (Str x) (Str y) = x == y
deepequal (JList x) (JList y) = length x == length y && and (zipWith deepequal x y)
deepequal (JMap x) (JMap y) =
  length x == length y
    && all (\(key, entry) -> maybe False (deepequal entry) (lookup key y)) x
deepequal _ _ = False

-- ---- regex engine ----------------------------------------------------

-- Omni specs match error messages with @/pattern/@ expectations, so every
-- port needs a regex. Haskell has none in base, so omni carries this
-- engine, a direct port of the Rust one (rust/src/regex.rs).

data ClassItem
  = IChar Char
  | IRange Char Char
  | IDigit Bool
  | IWord Bool
  | ISpace Bool

data Node
  = RChar Char
  | RAny
  | RClass [ClassItem] Bool
  | RStart
  | REnd
  | RSeq [Node]
  | RAlt [Node]
  | RRepeat Node Int (Maybe Int) Bool

regexParse :: String -> Maybe Node
regexParse pattern = case parseAlt pattern of
  Just (node, "") -> Just node
  _ -> Nothing

parseAlt :: String -> Maybe (Node, String)
parseAlt text = do
  (first, rest) <- parseSeq text
  branches rest [first]
  where
    branches ('|' : more) acc = do
      (branch, rest) <- parseSeq more
      branches rest (branch : acc)
    branches rest acc =
      Just (if 1 == length acc then head acc else RAlt (reverse acc), rest)

parseSeq :: String -> Maybe (Node, String)
parseSeq = collect []
  where
    collect acc text
      | null text || '|' == head text || ')' == head text = Just (RSeq (reverse acc), text)
      | otherwise = do
          (atom, rest) <- parseAtom text
          (node, more) <- parseRepeat atom rest
          collect (node : acc) more

parseRepeat :: Node -> String -> Maybe (Node, String)
parseRepeat atom text = case text of
  '*' : rest -> greedy atom 0 Nothing rest
  '+' : rest -> greedy atom 1 Nothing rest
  '?' : rest -> greedy atom 0 (Just 1) rest
  '{' : _ -> case parseCount text of
    Just (low, high, rest) -> greedy atom low high rest
    Nothing -> Just (atom, text)
  _ -> Just (atom, text)
  where
    greedy inner low high ('?' : rest) = Just (RRepeat inner low high False, rest)
    greedy inner low high rest = Just (RRepeat inner low high True, rest)

parseCount :: String -> Maybe (Int, Maybe Int, String)
parseCount ('{' : rest) =
  let (lowtext, afterlow) = span isDigit rest
   in if null lowtext
        then Nothing
        else case afterlow of
          '}' : more -> Just (read lowtext, Just (read lowtext), more)
          ',' : more ->
            let (hightext, afterhigh) = span isDigit more
             in case afterhigh of
                  '}' : final ->
                    Just (read lowtext, if null hightext then Nothing else Just (read hightext), final)
                  _ -> Nothing
          _ -> Nothing
parseCount _ = Nothing

parseAtom :: String -> Maybe (Node, String)
parseAtom [] = Nothing
parseAtom ('(' : rest) = do
  let inner = if "?:" `isPrefixOf` rest then drop 2 rest else rest
  (node, more) <- parseAlt inner
  case more of
    ')' : final -> Just (node, final)
    _ -> Nothing
parseAtom ('[' : rest) = parseClass rest
parseAtom ('.' : rest) = Just (RAny, rest)
parseAtom ('^' : rest) = Just (RStart, rest)
parseAtom ('$' : rest) = Just (REnd, rest)
parseAtom ('\\' : escape : rest) = Just (escapeNode escape, rest)
parseAtom (ch : rest) = Just (RChar ch, rest)

escapeNode :: Char -> Node
escapeNode escape = case escape of
  'd' -> RClass [IDigit False] False
  'D' -> RClass [IDigit False] True
  'w' -> RClass [IWord False] False
  'W' -> RClass [IWord False] True
  's' -> RClass [ISpace False] False
  'S' -> RClass [ISpace False] True
  'n' -> RChar '\n'
  'r' -> RChar '\r'
  't' -> RChar '\t'
  other -> RChar other

parseClass :: String -> Maybe (Node, String)
parseClass text =
  let (negated, rest) = case text of
        '^' : more -> (True, more)
        _ -> (False, text)
   in collect [] True negated rest
  where
    collect _ _ _ [] = Nothing
    collect acc first negated (']' : rest)
      | not first = Just (RClass (reverse acc) negated, rest)
      | otherwise = collect (IChar ']' : acc) False negated rest
    collect acc _ negated ('\\' : escape : rest) =
      collect (classEscape escape : acc) False negated rest
    collect acc _ negated (from : '-' : to : rest)
      | ']' /= to = collect (IRange from to : acc) False negated rest
    collect acc _ negated (ch : rest) = collect (IChar ch : acc) False negated rest

    classEscape escape = case escape of
      'd' -> IDigit False
      'w' -> IWord False
      's' -> ISpace False
      'n' -> IChar '\n'
      'r' -> IChar '\r'
      't' -> IChar '\t'
      other -> IChar other

isWordChar :: Char -> Bool
isWordChar ch = isAlphaNum ch || '_' == ch

classMatch :: [ClassItem] -> Bool -> Char -> Bool
classMatch items negated ch = hit /= negated
  where
    hit = any check items
    check item = case item of
      IChar want -> ch == want
      IRange from to -> from <= ch && ch <= to
      IDigit invert -> isDigit ch /= invert
      IWord invert -> isWordChar ch /= invert
      ISpace invert -> isSpace ch /= invert

matchNode :: Node -> String -> Int -> Int -> (Int -> Bool) -> Bool
matchNode node text len pos cont = case node of
  RChar want -> pos < len && (text !! pos) == want && cont (pos + 1)
  RAny -> pos < len && cont (pos + 1)
  RClass items negated -> pos < len && classMatch items negated (text !! pos) && cont (pos + 1)
  RStart -> 0 == pos && cont pos
  REnd -> len == pos && cont pos
  RSeq nodes -> matchSeq nodes text len pos cont
  RAlt branches -> any (\branch -> matchNode branch text len pos cont) branches
  RRepeat inner low high greedy -> matchRepeat inner low high greedy 0 text len pos cont

matchSeq :: [Node] -> String -> Int -> Int -> (Int -> Bool) -> Bool
matchSeq [] _ _ pos cont = cont pos
matchSeq (node : rest) text len pos cont =
  matchNode node text len pos (\next -> matchSeq rest text len next cont)

matchRepeat :: Node -> Int -> Maybe Int -> Bool -> Int -> String -> Int -> Int -> (Int -> Bool) -> Bool
matchRepeat inner low high greedy count text len pos cont =
  if greedy then takemore || stopnow else stopnow || takemore
  where
    canmore = maybe True (count <) high

    takemore =
      canmore
        && matchNode
          inner
          text
          len
          pos
          -- A zero-width repeat would loop forever.
          (\next -> next > pos && matchRepeat inner low high greedy (count + 1) text len next cont)

    stopnow = count >= low && cont pos

-- | Is the pattern found anywhere in the text?
regexFind :: String -> String -> Bool
regexFind pattern text = case regexParse pattern of
  Nothing -> False
  Just root -> any (\start -> matchNode root text len start (const True)) [0 .. len]
  where
    len = length text

-- ---- runner ----------------------------------------------------------

-- | The function under test. Arguments arrive as JSON values; failure is
-- reported by throwing.
type Subject = [Json] -> IO Json

-- | A subject that may REPLACE its arguments, which @match.args@ can then
-- assert on. @minor/setpath@ is the case in point: eight of its nine entries
-- assert that the store was rewritten in place, and @merge/integrity@ all six.
--
-- Haskell's 'Json' is immutable, so a consumer holding a converted copy has no
-- way to write through the argument list even when its own nodes are mutable
-- (struct/haskell keeps them in 'IORef' cells). Returning the arguments
-- alongside the result is the only channel there is.
--
-- Separate from 'Subject' rather than replacing it: a signature change would
-- break every consumer for a capability most subjects do not need. omni-rust,
-- omni-cpp, omni-ocaml and omni-elixir carry the same pair, for the same
-- reason.
type SubjectArgs = [Json] -> IO ([Json], Json)

-- | Run-time options for a set of test entries.
data Flags = Flags {flagNull :: Bool, flagName :: Maybe String}

defaultFlags :: Flags
defaultFlags = Flags {flagNull = True, flagName = Nothing}

nonullFlags :: Flags
nonullFlags = Flags {flagNull = False, flagName = Nothing}

-- | The host of the system under test. Every hook is optional.
data Provider = Provider
  { providerSubject :: Maybe (String -> Maybe Subject),
    providerClient :: Maybe (Json -> Provider),
    providerContextify :: Maybe (Json -> Json),
    providerInject :: Maybe (Json -> Json -> Json)
  }

emptyProvider :: Provider
emptyProvider =
  Provider
    { providerSubject = Nothing,
      providerClient = Nothing,
      providerContextify = Nothing,
      providerInject = Nothing
    }

-- | What a runner returns for one named spec section.
data RunPack = RunPack
  { packSpec :: Json,
    packSet :: String -> Json,
    runset :: Json -> Maybe Subject -> IO (),
    runsetFlags :: Json -> Flags -> Maybe Subject -> IO (),
    -- | Everything 'runsetFlags' does, for a subject that may replace its
    -- arguments. See 'SubjectArgs'.
    runsetFlagsArgs :: Json -> Flags -> SubjectArgs -> IO (),
    packSubject :: Maybe Subject,
    packClient :: Provider
  }

-- | The newest spec format version this runner understands. A spec with
-- no OMNI block is version 0: the original, lenient format, frozen
-- forever. Version 1 turns on strict entry validation (see checkentry).
specversion :: Int
specversion = 1

-- | Capability strings this runner supports beyond the version baseline.
-- A spec's OMNI.requires list is checked against this: an unknown
-- capability refuses the spec loudly at load time, instead of a lagging
-- port silently mis-running it. (Empty today; future format features
-- mint a string here.)
capabilities :: [String]
capabilities = []

-- | The complete set of fields an entry may carry. Under version 1
-- anything else is an error: an unrecognised key is almost always a
-- typo'd assertion, and a typo'd assertion is a test that silently
-- stopped testing.
entryfields :: [String]
entryfields = ["in", "args", "ctx", "out", "err", "match", "client", "id", "doc"]

-- | Read the spec's format version from its optional top-level OMNI
-- block, and refuse a spec this runner cannot faithfully run: a version
-- newer than specversion, or a required capability not in capabilities.
resolveversion :: Json -> IO Int
resolveversion alltests
  -- A present-but-null (or otherwise non-map) OMNI block is malformed;
  -- only a genuinely absent key is legacy version 0 - presence, not
  -- definedness, is the test.
  | not (jhas alltests "OMNI") = pure 0
  | otherwise = do
      let meta = jget alltests "OMNI"

      version <- case (asmap meta, asnum (jget meta "version")) of
        (Just _, Just num)
          | num == fromIntegral (truncate num :: Integer) -> pure (round num :: Int)
        _ -> throwIO (OmniError "omni: malformed OMNI version block")

      if version < 0 || specversion < version
        then throwIO (OmniError ("omni: unsupported spec version: " ++ show version))
        else pure ()

      -- `requires` present but null (or otherwise not a list) is
      -- malformed; a genuinely absent key skips the check.
      if jhas meta "requires"
        then case aslist (jget meta "requires") of
          Nothing -> throwIO (OmniError "omni: malformed OMNI requires list")
          Just caps -> mapM_ checkcap caps
        else pure ()

      pure version
  where
    checkcap cap = case asstr cap of
      Just text | text `elem` capabilities -> pure ()
      _ -> throwIO (OmniError ("omni: spec requires unsupported capability: " ++ stringify cap))

-- | Strict entry validation, applied when the spec declares version 1 or
-- later. The lenient format converts each of these mistakes into a
-- silent pass or a dead field; here they fail with the entry named.
checkentry :: String -> Int -> Json -> IO ()
checkentry label index entry
  | not (ismap entry) = throwIO (failure label index entry "entry is not a map" Nothing Nothing)
  | otherwise = do
      mapM_ checkfield (map fst (fromMaybe [] (asmap entry)))

      let argsources = length (filter (jhas entry) ["in", "args", "ctx"])
      if 1 < argsources
        then throwIO (failure label index entry "entry has more than one of in, args, ctx" Nothing Nothing)
        else pure ()

      if not (isnone (jget entry "err")) && jhas entry "out"
        then throwIO (failure label index entry "entry has both err and out" Nothing Nothing)
        else pure ()

      -- Presence, not definedness: an authored `id: null` must fail here,
      -- before null-normalisation can rewrite it into a sentinel string.
      let entryid = jget entry "id"
      if not (isabsent entryid) && not (isJust (asstr entryid))
        then throwIO (failure label index entry "entry id is not a string" Nothing Nothing)
        else pure ()
  where
    checkfield key =
      if key `elem` entryfields
        then pure ()
        else throwIO (failure label index entry ("unknown entry field: " ++ key) Nothing Nothing)

-- | Validate a version-1 group up front, against the AUTHORED entries -
-- null-normalisation would otherwise rewrite an authored null (e.g.
-- id: null) into a sentinel string and hide it from validation. A
-- malformed spec is a spec error, not a test result, so it fails before
-- any subject runs.
checkset :: String -> Json -> [Json] -> IO ()
checkset label testspec normalset = do
  let origset = case (asmap testspec, aslist (jget testspec "set")) of
        (Just _, Just list) -> list
        _ -> normalset

      isemptymarked = case jget testspec "empty" of
        Bool True -> True
        _ -> False

  if null origset && not isemptymarked
    then throwIO (OmniError ("omni: empty test set: " ++ label))
    else pure ()

  mapM_ (\(index, entry) -> checkentry label index entry) (zip [0 :: Int ..] origset)

-- | Find @primary.\<name\>@, then @\<name\>@, then the whole spec.
resolvespec :: String -> Json -> Json
resolvespec name alltests
  | null name = alltests
  | not (isabsent primary) = primary
  | not (isabsent section) = section
  | otherwise = alltests
  where
    primary = jget (jget alltests "primary") name
    section = jget alltests name

-- | Nulls (and absent values) become NULLMARK. Always a fresh copy.
fixjson :: Json -> Bool -> Json
fixjson value donull
  -- Canonical returns the value UNCHANGED when donull is false
  -- (typescript/src/Runner.ts): absent stays absent and null stays null.
  -- Answering Null for both collapsed two states the corpus distinguishes,
  -- so a subject that correctly returned nothing was compared against null
  -- and marked wrong. Same defect the other ports carried (#17, #23, #25,
  -- #26, #27); this one was missed because no consumer had exercised it.
  | isnone value = if donull then Str nullmark else value
  | otherwise = case value of
      JList entries -> JList (map (`fixjson` donull) entries)
      JMap entries -> JMap (map (\(key, entry) -> (key, fixjson entry donull)) entries)
      other -> other

-- | The JSON form of an error: always at least {name,message}.
errify :: String -> Json
errify message = JMap [("name", Str "Error"), ("message", Str message)]

-- | The message an @err@ expectation matches.
errmessage :: SomeException -> String
errmessage = displayException

-- | Match one leaf: \/regex\/ or case-insensitive substring for strings.
matchval :: Json -> Json -> Bool
matchval check base
  | deepequal check base = True
  | isnone want = isnone base || asstr base == Just nullmark
  | otherwise = case asstr want of
      -- An empty want is not a wildcard: the empty string is a substring of
      -- everything, so `match:{out:""}` (or `err:""`) would accept any value.
      Just "" -> asstr base == Just ""
      Just text ->
        let basestr = stringify base
         in if length text > 2 && "/" `isPrefixOf` text && "/" == [last text]
              then regexFind (init (drop 1 text)) basestr
              else map toLower text `isInfixOf` map toLower basestr
      Nothing -> deepequal want base
  where
    want = case asstr check of
      Just text | text == undefmark || text == nullmark -> Null
      _ -> check

-- | Convert NULLMARK sentinels back into real nulls.
nullmodifier :: Json -> Json
nullmodifier value = case asstr value of
  Just text | text == nullmark -> Null
  Just text -> Str (replace nullmark "null" text)
  Nothing -> value
  where
    replace _ _ [] = []
    replace from to text@(ch : rest)
      | from `isPrefixOf` text = to ++ replace from to (drop (length from) text)
      | otherwise = ch : replace from to rest

-- The spec-defined part of an entry (drop runner bookkeeping).
entrysummary :: Json -> Json
entrysummary (JMap entries) =
  JMap (filter (\(key, _) -> key /= "res" && key /= "thrown" && key /= "ctx") entries)
entrysummary other = other

-- The label of one entry, for failure messages.
entryref :: String -> Int -> Json -> String
entryref label index entry = label ++ "[" ++ show index ++ "]" ++ idpart
  where
    entryid = jget entry "id"
    idpart = if isabsent entryid then "" else " (" ++ stringify entryid ++ ")"

failure :: String -> Int -> Json -> String -> Maybe String -> Maybe String -> OmniError
failure label index entry reason expected actual =
  OmniError
    ( "omni: "
        ++ entryref label index entry
        ++ ": "
        ++ reason
        ++ maybe "" ("\n  expected: " ++) expected
        ++ maybe "" ("\n  actual:   " ++) actual
        ++ "\n  entry:    "
        ++ stringify (entrysummary entry)
    )

-- Check that every leaf of `check` is present, and matches, in `base`.
matchcheck :: String -> Int -> Json -> Json -> Json -> [String] -> IO ()
matchcheck label index entry check base path = case check of
  JList entries ->
    mapM_
      (\(at, subcheck) -> matchcheck label index entry subcheck base (path ++ [show at]))
      (zip [0 :: Int ..] entries)
  JMap entries ->
    mapM_
      (\(key, subcheck) -> matchcheck label index entry subcheck base (path ++ [key]))
      entries
  leaf -> checkleaf leaf
  where
    place = if null path then "<root>" else pathify path
    baseval = getpath base path

    bad reason expected actual =
      throwIO (failure label index entry (reason ++ place) (Just expected) (Just actual))

    -- The sentinels are tested BEFORE the identity check below.
    -- Otherwise a subject returning the literal string "__UNDEF__"
    -- satisfies an assertion that the key is absent - two mutually
    -- exclusive states passing one check. A sentinel that accepts its own
    -- literal is not a sentinel. (NULLMARK still accepts NULLMARK: under
    -- the default null flag a real null has already been normalised to
    -- it, so the two are genuinely indistinguishable here - that one
    -- needs a raw-value escape, not an ordering change.)
    checkleaf leaf
      -- Explicitly absent: satisfied only by a genuinely missing key,
      -- never by a present null (the distinction the sentinels keep).
      | asstr leaf == Just undefmark =
          if isabsent baseval
            then pure ()
            else bad "expected absent at " "absent" (stringify baseval)
      -- Explicitly null: satisfied only by a present null.
      | asstr leaf == Just nullmark =
          if isnull baseval || asstr baseval == Just nullmark
            then pure ()
            else bad "expected null at " "null" (stringify baseval)
      -- Explicitly present: any present value, including null.
      | asstr leaf == Just existsmark =
          if not (isabsent baseval)
            then pure ()
            else bad "expected present at " "present" "absent"
      -- Identical values match. This sits below the sentinel branches on
      -- purpose - see the note above.
      | deepequal leaf baseval = pure ()
      -- A concrete expectation never matches a missing key - a match
      -- leaf against an absent value must fail, not substring-match
      -- "undefined".
      | isabsent baseval = bad "match failed at " (stringify leaf) "absent"
      | matchval leaf baseval = pure ()
      | otherwise = bad "match failed at " (stringify leaf) (stringify baseval)

checkresult :: String -> Int -> Json -> [Json] -> Json -> IO ()
checkresult label index entry args res = do
  let entryerr = jget entry "err"

  if not (isnone entryerr)
    then
      throwIO
        ( failure
            label
            index
            entry
            "expected error did not occur"
            (Just (stringify entryerr))
            (Just (stringify res))
        )
    else pure ()

  let check = jget entry "match"
      matched = not (isnone check)

  if matched
    then
      matchcheck
        label
        index
        entry
        check
        ( JMap
            [ ("in", jget entry "in"),
              ("args", JList args),
              ("out", jget entry "res"),
              ("ctx", jget entry "ctx")
            ]
        )
        []
    else pure ()

  let out = jget entry "out"

  if deepequal res out
    then pure ()
    else
      -- NOTE: a match with no explicit out is a complete check on its own.
      if matched && (isnone out || asstr out == Just nullmark)
        then pure ()
        else
          throwIO
            (failure label index entry "result mismatch" (Just (stringify out)) (Just (stringify res)))

handleerror :: String -> Int -> Json -> String -> IO ()
handleerror label index entry message = do
  let entryerr = jget entry "err"

  if isnone entryerr
    then throwIO (failure label index entry "unexpected error" Nothing (Just message))
    else do
      let istrue = case entryerr of
            Bool True -> True
            _ -> False

      if istrue || matchval entryerr (Str message)
        then do
          let check = jget entry "match"
          if not (isnone check)
            then
              matchcheck
                label
                index
                entry
                check
                ( JMap
                    [ ("in", jget entry "in"),
                      ("out", jget entry "res"),
                      ("ctx", jget entry "ctx"),
                      ("err", errify message)
                    ]
                )
                []
            else pure ()
        else
          throwIO
            ( failure
                label
                index
                entry
                "error mismatch"
                (Just (stringify entryerr))
                (Just message)
            )

-- | Make a runner for a spec value and a provider.
makeRunnerSpec :: Json -> Provider -> String -> IO RunPack
makeRunnerSpec alltests provider name = do
  -- Resolved once, immediately after the spec is available - fail fast on
  -- an unsupported version rather than mid-run.
  specver <- resolveversion alltests

  let spec = resolvespec name alltests

      clients = case (asmap (jget (jget spec "DEF") "client"), providerClient provider) of
        (Just entries, Just clientmaker) ->
          map
            ( \(clientname, cdef) ->
                let copts = jget (jget cdef "test") "options"
                 in (clientname, clientmaker (if isabsent copts then JMap [] else copts))
            )
            entries
        _ -> []

      defsubject = case providerSubject provider of
        Just resolve | not (null name) -> resolve name
        _ -> Nothing

      runsetflags testspec flags testsubject =
        drive testspec flags testsubject Nothing

      runsetflagsargs testspec flags argsubject =
        drive testspec flags Nothing (Just argsubject)

      drive testspec flags testsubject argsubject = do
        let label = fromMaybe (if null name then "set" else name) (flagName flags)

        subject <- case (argsubject, testsubject, defsubject) of
          (Just _, _, _) -> pure Nothing
          (Nothing, Just found, _) -> pure (Just found)
          (Nothing, Nothing, Just found) -> pure (Just found)
          _ -> throwIO (OmniError ("omni: no test subject for: " ++ label))

        let testspecmap = fixjson testspec (flagNull flags)

        testset <- case aslist (jget testspecmap "set") of
          Just entries -> pure entries
          Nothing -> throwIO (OmniError ("omni: test spec has no set: " ++ label))

        if 1 <= specver
          then checkset label testspec testset
          else pure ()

        mapM_ (runentry label subject argsubject clients flags) (zip [0 ..] testset)

      runentry label subject argsubject clients' flags (index, rawentry) = do
        if not (ismap rawentry)
          then throwIO (OmniError ("omni: " ++ label ++ "[" ++ show index ++ "]: entry is not a map"))
          else pure ()

        -- An entry with no `out` expects a null (or absent) result.
        let entry0 =
              if flagNull flags && isnone (jget rawentry "out")
                then jset rawentry "out" (Str nullmark)
                else rawentry

        entrysubject <- case (subject, asstr (jget entry0 "client")) of
          (Nothing, _) -> pure Nothing
          (Just found, Just clientname) -> case lookup clientname clients' of
            Nothing -> throwIO (OmniError ("omni: unknown client: " ++ clientname))
            Just client -> case providerSubject client of
              Just resolve -> pure (Just (fromMaybe found (resolve name)))
              Nothing -> pure (Just found)
          (Just found, Nothing) -> pure (Just found)

        -- Build the argument list: `ctx`, `args`, or `in`.
        let hasctx = jhas entry0 "ctx"
            hasargs = jhas entry0 "args"

            args0
              | hasctx = [jget entry0 "ctx"]
              | hasargs = fromMaybe [jget entry0 "args"] (aslist (jget entry0 "args"))
              | otherwise = [clone (jget entry0 "in")]

            (args, entry) =
              if (hasctx || hasargs) && not (null args0) && ismap (head args0)
                then
                  let contextified = case providerContextify provider of
                        Just contextify -> contextify (head args0)
                        Nothing -> head args0
                      -- The resolved client is a live Provider (closures
                      -- over the system under test), and this port's Json
                      -- carries no host-object variant to hold one - so
                      -- canonical's `first.client = testpack.client`
                      -- becomes presence, not identity: enough for a
                      -- subject to prove the runner attached a client.
                      first = jset contextified "client" (Bool True)
                   in (first : tail args0, jset entry0 "ctx" first)
                else (args0, entry0)

        -- An args-subject returns its arguments alongside the result, so
        -- `match.args` sees what the subject actually did with them.
        let invoke = case (argsubject, entrysubject) of
              (Just call, _) -> call args
              (Nothing, Just call) -> (,) args <$> call args
              (Nothing, Nothing) ->
                throwIO (OmniError ("omni: no test subject for: " ++ label))

        outcome <- try invoke

        case outcome of
          Right (callargs, rawres) -> do
            let res = fixjson rawres (flagNull flags)
            checkresult label index (jset entry "res" res) callargs res
          Left err -> case fromOmni err of
            Just omnierr -> throwIO omnierr
            Nothing -> handleerror label index entry (errmessage err)

  pure
    RunPack
      { packSpec = spec,
        packSet = jget spec,
        runset = \testspec testsubject -> runsetflags testspec defaultFlags testsubject,
        runsetFlags = runsetflags,
        runsetFlagsArgs = runsetflagsargs,
        packSubject = defsubject,
        packClient = provider
      }

-- An OmniError raised inside a subject is a runner failure, not a
-- candidate for an `err` expectation.
fromOmni :: SomeException -> Maybe OmniError
fromOmni = fromException

-- | Make a runner for a spec file path and a provider.
makeRunner :: String -> Provider -> String -> IO RunPack
makeRunner path provider name = do
  alltests <- loadspec path
  makeRunnerSpec alltests provider name
