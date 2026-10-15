-- RUN: make test
-- RUN-SOME: ./build/omnitest basic
--
-- The Fibonacci conformance suite: every omni port runs this same set of
-- groups, from the same spec/fib.json, against the same fib library.
--
-- No third-party test framework: a failing omni check throws OmniError, so
-- hspec or tasty reports it as a failure. This harness keeps `make test`
-- dependency-free.

module Main (main) where

import Control.Exception (SomeException, fromException, throw, throwIO, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Fib
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Omni
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, stdout)

-- Find the shared spec directory by walking up from the working directory.
specfile :: String -> IO String
specfile name = search "." (0 :: Int)
  where
    search dir step
      | step >= 8 = throwIO (OmniError ("omni: spec not found: " ++ name))
      | otherwise = do
          let cand = dir ++ "/spec/" ++ name
          found <- try (readFile cand) :: IO (Either SomeException String)
          case found of
            Right _ -> pure cand
            Left _ -> search (dir ++ "/..") (step + 1)

fibsub :: Subject
fibsub args = fib (head args)

fibseqsub :: Subject
fibseqsub args = fibseq (head args)

fibrangesub :: Subject
fibrangesub args = fibrange (head args) (args !! 1)

fibinfosub :: Subject
fibinfosub args = fibinfo (head args)

-- A subject that returns the literal string "__UNDEF__" as ordinary data.
-- The sentinel must not accept its own literal: this result is a present
-- key, so a `__UNDEF__` (absent) assertion against it has to fail.
fibundeflitsub :: Subject
fibundeflitsub _ = pure (JMap [("a", Str "__UNDEF__")])

-- The context-group subject: reports what the runner delivered - the
-- contextify mark and the attached client - as plain data, so the spec
-- can pin both with an ordinary `out` comparison.
fibctxsub :: Subject
fibctxsub args = do
  let ctx = head args
  val <- fib (jget ctx "n")
  pure
    ( JMap
        [ ("n", jget ctx "n"),
          ("val", val),
          ("mark", jget ctx "mark"),
          ("hasclient", Bool (not (isnone (jget ctx "client"))))
        ]
    )

-- The provider hosts the system under test. `shift` offsets the Fibonacci
-- index, so that a client-specific subject is observably different.
-- `contextify` marks the map, so the context group can prove the hook ran.
fibprovider :: Double -> Provider
fibprovider shift =
  emptyProvider
    { providerSubject = Just resolve,
      providerClient = Just client,
      providerContextify = Just (\val -> jset val "mark" (Str "CTX"))
    }
  where
    resolve name = case name of
      "fib" -> Just shifted
      "fibseq" -> Just fibseqsub
      "fibrange" -> Just fibrangesub
      "fibinfo" -> Just fibinfosub
      _ -> Nothing

    shifted args = case asnum (head args) of
      Just num -> fib (Num (num + shift))
      Nothing -> fib (head args)

    client options = fibprovider (maybe 0 id (asnum (jget options "shift")))

-- | Derive fib's error code from its message.
fiberrcode :: String -> String
fiberrcode message
  | has "negative index" = "fib_negative"
  | has "non-integer" = "fib_noninteger"
  | has "not a number" = "fib_notanumber"
  | otherwise = "fib_unknown"
  where
    has needle = needle `isInfixOf` message

-- | The same provider, plus the errify hook: fib's errors gain a CODE.
--
-- A SECOND runner rather than a hook on 'fibprovider', so that the
-- @error@ group keeps exercising the DEFAULT errify.
fibcodedprovider :: Provider
fibcodedprovider =
  (fibprovider 0)
    { providerErrify =
        Just
          ( \message ->
              JMap
                [ ("name", Str "Error"),
                  ("message", Str message),
                  ("code", Str (fiberrcode message))
                ]
          )
    }

testcase :: IORef Int -> IORef Int -> Maybe String -> String -> IO () -> IO ()
testcase passcount failcount only name body =
  case only of
    Just wanted | wanted /= name -> pure ()
    _ -> do
      outcome <- try body :: IO (Either SomeException ())
      case outcome of
        Right () -> do
          modifyIORef' passcount (+ 1)
          putStrLn ("ok   - " ++ name)
        Left err -> do
          modifyIORef' failcount (+ 1)
          putStrLn ("FAIL - " ++ name)
          putStrLn (errmessage err)
      hFlush stdout

-- The runner must fail when the subject is wrong - otherwise a green suite
-- means nothing.
badspec :: Json
badspec =
  JMap
    [ ( "fib",
        JMap
          [ ( "wrongout",
              JMap
                [ ( "set",
                    JList
                      [ JMap [("in", Num 5), ("out", Num 5)],
                        JMap [("in", Num 6), ("out", Num 999)]
                      ]
                  )
                ]
            ),
            ( "wrongerr",
              JMap [("set", JList [JMap [("in", Num 1), ("err", Str "never happens")]])]
            ),
            ( "wrongmatch",
              JMap
                [("set", JList [JMap [("in", Num 6), ("match", JMap [("out", Num 999)])]])]
            ),
            ( "missing",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 6),
                            ("match", JMap [("out", JMap [("nope", Str "__EXISTS__")])])
                          ]
                      ]
                  )
                ]
            ),
            -- A concrete match leaf against a missing key must fail, not
            -- substring-match the text "undefined".
            ( "matchabsent",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 6),
                            ("match", JMap [("out", JMap [("nope", Str "fine")])])
                          ]
                      ]
                  )
                ]
            ),
            -- __UNDEF__ (absent) must not be satisfied by the literal
            -- string "__UNDEF__" returned as ordinary data.
            ( "wrongundef",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 6),
                            ("match", JMap [("out", JMap [("a", Str "__UNDEF__")])])
                          ]
                      ]
                  )
                ]
            ),
            -- __UNDEF__ (absent) must not be satisfied by a present null.
            ( "undefonnull",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 0),
                            ("match", JMap [("out", JMap [("prev", Str "__UNDEF__")])])
                          ]
                      ]
                  )
                ]
            ),
            -- __NULL__ (present null) must not be satisfied by an absent key.
            ( "nullonabsent",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 6),
                            ("match", JMap [("out", JMap [("nope", Str "__NULL__")])])
                          ]
                      ]
                  )
                ]
            ),
            -- An empty-string match leaf is not a wildcard.
            ( "emptystr",
              JMap
                [ ( "set",
                    JList
                      [ JMap
                          [ ("in", Num 6),
                            ("match", JMap [("out", JMap [("label", Str "")])])
                          ]
                      ]
                  )
                ]
            )
          ]
      )
    ]

expectfail :: String -> Subject -> IO ()
expectfail setname subject = do
  pack <- makeRunnerSpec badspec emptyProvider "fib"
  outcome <- try (runset pack (packSet pack setname) (Just subject)) :: IO (Either SomeException ())
  case outcome of
    Left err -> case fromException err :: Maybe OmniError of
      Just _ -> pure ()
      Nothing -> throwIO err
    Right () -> throwIO (OmniError ("omni: expected a failure for set: " ++ setname))

checkmessage :: IO ()
checkmessage = do
  let spec =
        JMap
          [ ( "fib",
              JMap
                [ ( "g",
                    JMap
                      [ ( "set",
                          JList
                            [ JMap [("in", Num 1), ("out", Num 1)],
                              JMap [("id", Str "x#2"), ("in", Num 2), ("out", Num 42)]
                            ]
                        )
                      ]
                  )
                ]
            )
          ]

  pack <- makeRunnerSpec spec emptyProvider "fib"
  outcome <- try (runset pack (packSet pack "g") (Just fibsub)) :: IO (Either SomeException ())

  case outcome of
    Right () -> throwIO (OmniError "omni: expected a failure")
    Left err -> do
      let message = errmessage err
      mapM_
        ( \want ->
            if want `isInfixOf` message
              then pure ()
              else throwIO (OmniError ("omni: message missing [" ++ want ++ "]: " ++ message))
        )
        ["fib[1] (x#2)", "expected: 42", "actual:   1"]

-- ---- version-1 validation (negative tests) ----------------------------
--
-- Version-1 validation raises either at load time (resolveversion, before
-- any group runs) or before any subject runs (checkset/checkentry) - both
-- paths raise an OmniError whose message names the reason.

requiretext :: String -> String -> IO ()
requiretext want message =
  if want `isInfixOf` message
    then pure ()
    else throwIO (OmniError ("omni: message missing [" ++ want ++ "]: " ++ message))

-- Expect makeRunnerSpec itself to refuse a malformed spec.
expectloadfail :: String -> Json -> IO ()
expectloadfail want spec = do
  outcome <- try (makeRunnerSpec spec emptyProvider "fib") :: IO (Either SomeException RunPack)
  case outcome of
    Right _ -> throwIO (OmniError ("omni: expected makeRunnerSpec to reject: " ++ want))
    Left err -> requiretext want (errmessage err)

-- Expect running group `setname` of `spec` to fail with a message
-- containing `want`.
expectrunfail :: String -> Json -> String -> Subject -> IO ()
expectrunfail want spec setname subject = do
  pack <- makeRunnerSpec spec emptyProvider "fib"
  outcome <- try (runset pack (packSet pack setname) (Just subject)) :: IO (Either SomeException ())
  case outcome of
    Right () -> throwIO (OmniError ("omni: expected a failure for set: " ++ setname))
    Left err -> requiretext want (errmessage err)

-- A version-1 spec whose fib.g group is the given entry set - the shape
-- every strict-validation negative test shares.
strictspec :: [Json] -> Json
strictspec entries =
  JMap
    [ ("OMNI", JMap [("version", Num 1)]),
      ("fib", JMap [("g", JMap [("set", JList entries)])])
    ]

rejectsUnsupportedVersion :: IO ()
rejectsUnsupportedVersion =
  expectloadfail
    "unsupported spec version"
    (JMap [("OMNI", JMap [("version", Num 99)]), ("fib", JMap [("g", JMap [("set", JList [])])])])

rejectsUnknownCapability :: IO ()
rejectsUnknownCapability =
  expectloadfail
    "unsupported capability"
    ( JMap
        [ ("OMNI", JMap [("version", Num 1), ("requires", JList [Str "nosuchfeature"])]),
          ("fib", JMap [("g", JMap [("set", JList [])])])
        ]
    )

rejectsMalformedVersionBlock :: IO ()
rejectsMalformedVersionBlock =
  expectloadfail
    "malformed OMNI"
    (JMap [("OMNI", JMap [("version", Str "one")]), ("fib", JMap [("g", JMap [("set", JList [])])])])

-- A present-but-null OMNI block is malformed; only a genuinely absent key
-- is legacy. Ports that test definedness rather than presence silently
-- skip strict mode here, so both cases are pinned.
rejectsNullOmniAcceptsAbsent :: IO ()
rejectsNullOmniAcceptsAbsent = do
  expectloadfail
    "malformed OMNI"
    ( JMap
        [ ("OMNI", Null),
          ("fib", JMap [("g", JMap [("set", JList [JMap [("in", Num 1), ("out", Num 1)]])])])
        ]
    )
  expectloadfail
    "malformed OMNI requires list"
    ( JMap
        [ ("OMNI", JMap [("version", Num 1), ("requires", Null)]),
          ("fib", JMap [("g", JMap [("set", JList [JMap [("in", Num 1), ("out", Num 1)]])])])
        ]
    )
  _ <-
    makeRunnerSpec
      (JMap [("fib", JMap [("g", JMap [("set", JList [JMap [("in", Num 1), ("out", Num 1)]])])])])
      emptyProvider
      "fib"
  pure ()

strictUnknownEntryField :: IO ()
strictUnknownEntryField =
  expectrunfail
    "unknown entry field: matches"
    (strictspec [JMap [("in", Num 6), ("matches", JMap [("out", Num 999)])]])
    "g"
    fibinfosub

strictMultipleArgSources :: IO ()
strictMultipleArgSources =
  expectrunfail
    "more than one of in, args, ctx"
    (strictspec [JMap [("in", Num 5), ("args", JList [Num 5]), ("out", Num 5)]])
    "g"
    fibsub

strictErrWithOut :: IO ()
strictErrWithOut =
  expectrunfail
    "both err and out"
    (strictspec [JMap [("in", Num (-1)), ("err", Bool True), ("out", Num 5)]])
    "g"
    fibsub

-- Catches Fix 1 (validation on the AUTHORED group, not the
-- null-normalised copy) and the id half of Fix 2 (presence, not
-- definedness) together: under default flags, a normalised `id: null`
-- becomes the string "__NULL__" and would otherwise slip past.
strictNullId :: IO ()
strictNullId =
  expectrunfail
    "entry id is not a string"
    (strictspec [JMap [("in", Num 1), ("out", Num 1), ("id", Null)]])
    "g"
    fibsub

strictEmptySet :: IO ()
strictEmptySet = do
  let spec =
        JMap
          [ ("OMNI", JMap [("version", Num 1)]),
            ( "fib",
              JMap
                [ ("g", JMap [("set", JList [])]),
                  ("h", JMap [("set", JList []), ("empty", Bool True)])
                ]
            )
          ]
  expectrunfail "empty test set" spec "g" fibsub
  pack <- makeRunnerSpec spec emptyProvider "fib"
  runset pack (packSet pack "h") (Just fibsub)

legacySpecStaysLenient :: IO ()
legacySpecStaysLenient = do
  let spec =
        JMap
          [ ( "fib",
              JMap
                [ ( "g",
                    JMap
                      [ ( "set",
                          JList
                            [JMap [("in", Num 6), ("matches", JMap [("out", Num 999)]), ("out", Num 8)]]
                        )
                      ]
                  )
                ]
            )
          ]
  pack <- makeRunnerSpec spec emptyProvider "fib"
  runset pack (packSet pack "g") (Just fibsub)

-- ---- deepequal: NaN is structurally equal to NaN ---------------------
--
-- deepequal is structural, not IEEE: two NaNs are equal however each one
-- was made (src/Omni.hs: `isNaN x && isNaN y`). Nothing in spec/fib.json
-- can pin that - JSON has no NaN literal - so it is pinned here.
--
-- The two NaNs come from different expressions and differ bit for bit. A
-- test that used one NaN constant twice could pass on an equality fast
-- path while proving nothing, so the distinctness is asserted first:
-- collapse the pair into a single shared constant and this test fails
-- loudly instead of going quiet.

nan1 :: Double
nan1 = 0 / 0

nan2 :: Double
nan2 = castWord64ToDouble 0x7FF8000000000001

checkequal :: Bool -> Json -> Json -> String -> IO ()
checkequal want a b label =
  if deepequal a b == want
    then pure ()
    else throwIO (OmniError ("omni: deepequal " ++ label ++ ": expected " ++ show want))

deepequalNaN :: IO ()
deepequalNaN = do
  if isNaN nan1 && isNaN nan2
    then pure ()
    else throwIO (OmniError "omni: nan1 and nan2 must both be NaN")
  if castDoubleToWord64 nan1 /= castDoubleToWord64 nan2
    then pure ()
    else throwIO (OmniError "omni: nan1 and nan2 must be two distinct NaN values")

  checkequal True (Num nan1) (Num nan2) "NaN, NaN"
  checkequal True (JList [Num nan1]) (JList [Num nan2]) "[NaN], [NaN]"
  checkequal True (JMap [("x", Num nan1)]) (JMap [("x", Num nan2)]) "{x: NaN}, {x: NaN}"

  -- Regressions: the NaN branch must not loosen anything else. Haskell
  -- has a single numeric constructor, so the int/float case is one Num
  -- value reached two ways.
  checkequal True (Num 1) (Num 1.0) "1, 1.0"
  checkequal False (Num nan1) (Num 1.0) "NaN, 1.0"
  checkequal False (Bool True) (Num 1) "True, 1"
  checkequal False (Num 1) (Num 2) "1, 2"

-- ---- capabilities (spec/ext.json) ------------------------------------

-- The ctxargs subject: the context comes first, and must arrive
-- contextified with its client attached.
fibshiftedsub :: Subject
fibshiftedsub args = case args of
  (ctx : start : end : _)
    | deepequal (jget ctx "mark") (Str "CTX") && not (isnone (jget ctx "client")) ->
        fibrange (shift ctx start) (shift ctx end)
  _ -> throwIO (FibError "fib: context not delivered")
  where
    shift ctx value = case (asnum value, asnum (jget ctx "shift")) of
      (Just num, Just by) -> Num (num + by)
      _ -> value

-- Expect `action` to raise an OmniError whose message matches `pattern`.
refuses :: IO () -> String -> IO ()
refuses action pattern = do
  outcome <- try action
  case outcome of
    Right () -> throwIO (OmniError ("omni: expected a failure matching: " ++ pattern))
    Left (OmniError message) ->
      if regexFind pattern message
        then pure ()
        else throwIO (OmniError ("omni: message does not match [" ++ pattern ++ "]: " ++ message))

extpack :: Json -> IO RunPack
extpack spec = makeRunnerSpec spec (fibprovider 0) "fib"

v1 :: [String] -> [Json] -> Json
v1 requires set =
  JMap
    [ ("OMNI", JMap [("version", Num 1), ("requires", JList (map Str requires))]),
      ("fib", JMap [("g", JMap [("set", JList set)])])
    ]

rung :: RunPack -> Subject -> IO ()
rung pack subject = runset pack (packSet pack "g") (Just subject)

rungwith :: RunPack -> RunFlags -> Subject -> IO ()
rungwith pack runflags subject = runsetWith pack (packSet pack "g") defaultFlags runflags (Just subject)

waitflag :: String -> String -> RunFlags
waitflag entryid cause = defaultRunFlags {flagWait = JMap [(entryid, JMap [("cause", Str cause)])]}

extCapabilities :: IO ()
extCapabilities =
  mapM_
    ( \cap ->
        if cap `elem` capabilities
          then pure ()
          else throwIO (OmniError ("omni: missing capability: " ++ cap))
    )
    ["ctxargs", "fn", "wait"]

waitingEntryPasses :: IO ()
waitingEntryPasses = do
  pack <- extpack (v1 ["wait"] [JMap [("in", Num 5), ("out", Num 5), ("wait", JMap [("cause", Str "gone#1")])]])
  refuses (rung pack fibsub) "\\[0\\]: stale wait: gone#1"

waitFlagHolds :: IO ()
waitFlagHolds = do
  pack <- extpack (v1 [] [JMap [("id", Str "a"), ("in", Num 6), ("out", Num 9)], JMap [("in", Num 7), ("out", Num 13)]])
  rungwith pack (waitflag "a" "flag#1") fibsub

waitFlagStale :: IO ()
waitFlagStale = do
  pack <- extpack (v1 [] [JMap [("id", Str "a"), ("in", Num 6), ("out", Num 8)]])
  refuses (rungwith pack (waitflag "a" "flag#1") fibsub) "stale wait: flag#1"

waitFlagNamesEntry :: IO ()
waitFlagNamesEntry = do
  pack <- extpack (v1 [] [JMap [("id", Str "a"), ("in", Num 6), ("out", Num 8)]])
  refuses (rungwith pack (waitflag "zz" "c") fibsub) "wait names no entry: zz"

waitNeedsCause :: IO ()
waitNeedsCause = do
  pack <- extpack (v1 ["wait"] [JMap [("in", Num 6), ("out", Num 9), ("wait", JMap [])]])
  refuses (rung pack fibsub) "entry wait has no cause"

unknownUnlessRequired :: IO ()
unknownUnlessRequired = do
  waitpack <- extpack (v1 [] [JMap [("in", Num 6), ("out", Num 9), ("wait", JMap [("cause", Str "c")])]])
  refuses (rung waitpack fibsub) "unknown entry field: wait"
  fnpack <- extpack (v1 [] [JMap [("fn", Str "fib"), ("in", Num 6), ("out", Num 8)]])
  refuses (rung fnpack fibsub) "unknown entry field: fn"

unknownFn :: IO ()
unknownFn = do
  pack <- extpack (v1 ["fn"] [JMap [("fn", Str "nope"), ("in", Num 6), ("out", Num 8)]])
  refuses (rung pack fibsub) "unknown fn: nope"

ctxWithArgs :: IO ()
ctxWithArgs = do
  nopack <-
    extpack
      ( v1
          []
          [ JMap
              [ ("ctx", JMap [("shift", Num 0)]),
                ("args", JList [Num 0, Num 1]),
                ("out", JList [Num 0, Num 1])
              ]
          ]
      )
  refuses (rung nopack fibshiftedsub) "more than one of in, args, ctx"
  inpack <-
    extpack (v1 ["ctxargs"] [JMap [("in", Num 1), ("ctx", JMap [("shift", Num 0)]), ("out", JList [Num 0])]])
  refuses (rung inpack fibshiftedsub) "entry has in beside args or ctx"

legacyIgnoresFnWait :: IO ()
legacyIgnoresFnWait = do
  let entry = JMap [("in", Num 6), ("out", Num 8), ("fn", Str "nope"), ("wait", JMap [("cause", Str "c")])]
  pack <- extpack (JMap [("fib", JMap [("g", JMap [("set", JList [entry])])])])
  rung pack fibsub

-- A hook raises from pure code, with the subject's own error type.
boomprovider :: Provider
boomprovider =
  emptyProvider
    { providerSubject = Just (const (Just fibsub)),
      providerContextify = Just (\_ -> throw (FibError "contextify boom"))
    }

raisingHook :: IO ()
raisingHook = do
  let run spec = makeRunnerSpec spec boomprovider "fib"
      ctx = ("ctx", JMap [("n", Num 6)])
  expected <- run (v1 [] [JMap [ctx, ("err", Str "contextify boom")]])
  rung expected fibsub
  unexpected <- run (v1 [] [JMap [ctx, ("out", Num 8)]])
  refuses (rung unexpected fibsub) "\\[0\\]: unexpected error\n\\s+actual:\\s+contextify boom"
  held <- run (v1 ["wait"] [JMap [ctx, ("out", Num 8), ("wait", JMap [("cause", Str "hook#1")])]])
  rung held fibsub
  let boom name = if "boom" == name then throw (FibError "subject boom") else Just fibsub
  fnpack <-
    makeRunnerSpec
      (v1 ["fn"] [JMap [("fn", Str "boom"), ("in", Num 6), ("err", Str "subject boom")]])
      emptyProvider {providerSubject = Just boom}
      "fib"
  rung fnpack fibsub

-- Laziness must not let a raising hook pass unseen: the runner forces the
-- arguments, whether or not the subject reads them.
raisingHookUnread :: IO ()
raisingHookUnread = do
  pack <- makeRunnerSpec (v1 [] [JMap [("ctx", JMap [("n", Num 6)]), ("out", Num 8)]]) boomprovider "fib"
  refuses (rung pack (const (pure (Num 8)))) "\\[0\\]: unexpected error\n\\s+actual:\\s+contextify boom"

waitHoldsPrestart :: IO ()
waitHoldsPrestart = do
  let resolve name
        | "boom" == name = throw (FibError "subject boom")
        | "fib" == name = Just fibsub
        | otherwise = Nothing
      run spec = makeRunnerSpec spec emptyProvider {providerSubject = Just resolve} "fib"
  held <- run (v1 ["fn", "wait"] [JMap [("fn", Str "boom"), ("in", Num 6), ("out", Num 8), ("wait", JMap [("cause", Str "hook#2")])]])
  rung held fibsub
  stale <-
    run (v1 ["fn", "wait"] [JMap [("fn", Str "boom"), ("in", Num 6), ("err", Str "subject boom"), ("wait", JMap [("cause", Str "hook#3")])]])
  refuses (rung stale fibsub) "\\[0\\]: stale wait: hook#3"

fnNeedsNoDefault :: IO ()
fnNeedsNoDefault = do
  let provider = emptyProvider {providerSubject = Just (\name -> if "fibx" == name then Just fibsub else Nothing)}
      run spec = makeRunnerSpec spec provider "fib"
      nosubject pack = runset pack (packSet pack "g") Nothing
      fibx = JMap [("fn", Str "fibx"), ("in", Num 6), ("out", Num 8)]
      plain = JMap [("in", Num 6), ("out", Num 8)]
  resolved <- run (v1 ["fn"] [fibx])
  nosubject resolved
  unnamed <- run (v1 ["fn"] [fibx, plain])
  refuses (nosubject unnamed) "^omni: no test subject for: fib$"
  legacy <- run (v1 [] [plain])
  refuses (nosubject legacy) "^omni: no test subject for: fib$"

waitOwnId :: IO ()
waitOwnId = do
  pack <- extpack (v1 [] [JMap [("id", Str "constructor"), ("in", Num 6), ("out", Num 8)], JMap [("id", Str "toString"), ("in", Num 7), ("out", Num 13)]])
  rung pack fibsub
  rungwith pack defaultRunFlags {flagWait = JMap []} fibsub

allReportsEvery :: IO ()
allReportsEvery = do
  pack <-
    extpack
      ( v1
          []
          [ JMap [("in", Num 5), ("out", Num 6)],
            JMap [("in", Num 6), ("out", Num 8)],
            JMap [("in", Num 7), ("out", Num 14)]
          ]
      )
  refuses
    (rungwith pack defaultRunFlags {flagAll = True} fibsub)
    "^omni: fib: 2 of 3 entries failed\n.*fib\\[0\\]: result mismatch.*fib\\[2\\]: result mismatch"
  refuses (rung pack fibsub) "^omni: fib\\[0\\]: result mismatch"

main :: IO ()
main = do
  args <- getArgs
  let only = case args of
        (first : _) -> Just first
        _ -> Nothing

  passcount <- newIORef 0
  failcount <- newIORef 0

  let run = testcase passcount failcount only

  path <- specfile "fib.json"
  pack <- makeRunner path (fibprovider 0) "fib"
  codedpack <- makeRunner path fibcodedprovider "fib"

  run "basic" (runset pack (packSet pack "basic") (Just fibsub))
  run "seq" (runset pack (packSet pack "seq") (Just fibseqsub))
  run "range" (runset pack (packSet pack "range") (Just fibrangesub))
  run "info" (runset pack (packSet pack "info") (Just fibinfosub))
  run "nulls" (runsetFlags pack (packSet pack "nulls") nonullFlags (Just fibinfosub))
  run "error" (runset pack (packSet pack "error") (Just fibsub))
  run "errcode" (runset codedpack (packSet codedpack "errcode") (Just fibsub))
  run "match" (runset pack (packSet pack "match") (Just fibsub))
  run "matchinfo" (runset pack (packSet pack "matchinfo") (Just fibinfosub))
  run "client" (runset pack (packSet pack "client") (Just fibsub))
  run "context" (runset pack (packSet pack "context") (Just fibctxsub))

  run "detects wrong result" (expectfail "wrongout" fibsub)
  run "detects missing error" (expectfail "wrongerr" fibsub)
  run "detects failed match" (expectfail "wrongmatch" fibsub)
  run "detects absent key" (expectfail "missing" fibinfosub)
  run "a concrete match leaf does not match a missing key" (expectfail "matchabsent" fibinfosub)
  run "__UNDEF__ does not match a present null" (expectfail "undefonnull" fibinfosub)
  run
    "__UNDEF__ does not match the literal \"__UNDEF__\" as data"
    (expectfail "wrongundef" fibundeflitsub)
  run "__NULL__ does not match an absent key" (expectfail "nullonabsent" fibinfosub)
  run "an empty-string match leaf is not a wildcard" (expectfail "emptystr" fibinfosub)

  run "rejects an unsupported spec version" rejectsUnsupportedVersion
  run "rejects an unknown required capability" rejectsUnknownCapability
  run "rejects a malformed version block" rejectsMalformedVersionBlock
  run "rejects a null OMNI block, but accepts an absent one" rejectsNullOmniAcceptsAbsent
  run "strict: an unknown entry field fails instead of passing vacuously" strictUnknownEntryField
  run "strict: more than one of in, args, ctx fails" strictMultipleArgSources
  run "strict: err together with out fails" strictErrWithOut
  run "strict: a null id fails even under null-normalisation" strictNullId
  run "strict: an empty set fails unless marked empty" strictEmptySet
  run "a legacy spec (no OMNI block) stays lenient" legacySpecStaysLenient

  run "reports entry index and id" checkmessage
  run "deepequal: NaN equals NaN, structurally" deepequalNaN

  extpath <- specfile "ext.json"
  ext <- makeRunner extpath (fibprovider 0) "fib"

  run "ext capabilities" extCapabilities
  run "ext ctxargs" (runset ext (packSet ext "ctxargs") (Just fibshiftedsub))
  run "ext fn" (runset ext (packSet ext "fn") (Just fibsub))
  run "ext wait" (runset ext (packSet ext "wait") (Just fibsub))

  run "a waiting entry that passes fails the set" waitingEntryPasses
  run "the wait flag holds an entry by id" waitFlagHolds
  run "the wait flag fails when its entry passes" waitFlagStale
  run "the wait flag must name an entry" waitFlagNamesEntry
  run "a wait needs a cause" waitNeedsCause
  run "wait and fn are unknown fields unless required" unknownUnlessRequired
  run "an unknown fn is a spec error" unknownFn
  run "ctx with args needs ctxargs, and never takes in" ctxWithArgs
  run "a legacy spec ignores fn and wait" legacyIgnoresFnWait
  run "a raising hook is the entry's error, not the set's" raisingHook
  run "a raising hook fails the entry even when the subject ignores its arguments" raisingHookUnread
  run "a waiting entry holds a hook's error raised before the subject starts" waitHoldsPrestart
  run "fn needs no default subject, but an entry without fn does" fnNeedsNoDefault
  run "a wait is found by an id the entry owns, never an inherited one" waitOwnId
  run "all reports every failure at once" allReportsEvery

  passed <- readIORef passcount
  failed <- readIORef failcount

  putStrLn ("\n" ++ show passed ++ " passed, " ++ show failed ++ " failed")

  if 0 == failed then exitSuccess else exitFailure
