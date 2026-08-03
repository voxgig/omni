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

-- The provider hosts the system under test. `shift` offsets the Fibonacci
-- index, so that a client-specific subject is observably different.
fibprovider :: Double -> Provider
fibprovider shift =
  emptyProvider
    { providerSubject = Just resolve,
      providerClient = Just client
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
            -- An empty container asserts an empty container, not "anything".
            ( "emptymatch",
              JMap
                [ ( "set",
                    JList [JMap [("in", Num 6), ("match", JMap [("out", JMap [])])]]
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

  run "detects wrong result" (expectfail "wrongout" fibsub)
  run "detects missing error" (expectfail "wrongerr" fibsub)
  run "detects failed match" (expectfail "wrongmatch" fibsub)
  run "detects absent key" (expectfail "missing" fibinfosub)
  run "a concrete match leaf does not match a missing key" (expectfail "matchabsent" fibinfosub)
  run "__UNDEF__ does not match a present null" (expectfail "undefonnull" fibinfosub)
  run "__NULL__ does not match an absent key" (expectfail "nullonabsent" fibinfosub)
  run "an empty match container is not vacuous" (expectfail "emptymatch" fibinfosub)
  run "an empty-string match leaf is not a wildcard" (expectfail "emptystr" fibinfosub)
  run "reports entry index and id" checkmessage

  passed <- readIORef passcount
  failed <- readIORef failcount

  putStrLn ("\n" ++ show passed ++ " passed, " ++ show failed ++ " failed")

  if 0 == failed then exitSuccess else exitFailure
