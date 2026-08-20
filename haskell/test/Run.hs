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

import Control.Exception (SomeException, fromException, throwIO, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Fib
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

  run "basic" (runset pack (packSet pack "basic") (Just fibsub))
  run "seq" (runset pack (packSet pack "seq") (Just fibseqsub))
  run "range" (runset pack (packSet pack "range") (Just fibrangesub))
  run "info" (runset pack (packSet pack "info") (Just fibinfosub))
  run "nulls" (runsetFlags pack (packSet pack "nulls") nonullFlags (Just fibinfosub))
  run "error" (runset pack (packSet pack "error") (Just fibsub))
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

  passed <- readIORef passcount
  failed <- readIORef failcount

  putStrLn ("\n" ++ show passed ++ " passed, " ++ show failed ++ " failed")

  if 0 == failed then exitSuccess else exitFailure
