-- | The system under test: a tiny Fibonacci library.
--
-- Every omni port ships this same library, with the same behaviour and the
-- same error messages, and tests it with the same spec file
-- (spec/fib.json).

module Fib (FibError (..), fibindex, fibnum, fib, fibseq, fibrange, fibinfo) where

import Control.Exception (Exception, throwIO)
import Omni

-- | The Fibonacci library's own error type. A subject must never throw the
-- runner's OmniError - that type is reserved for test failures.
newtype FibError = FibError String

instance Show FibError where
  show (FibError message) = message

instance Exception FibError

-- | Validate a Fibonacci index. The spec matches on these messages.
fibindex :: Json -> IO Int
fibindex value = case asnum value of
  Nothing -> throwIO (FibError ("fib: not a number: " ++ stringify value))
  Just num
    | num /= fromIntegral (truncate num :: Int) ->
        throwIO (FibError ("fib: non-integer index: " ++ stringify value))
    | num < 0 -> throwIO (FibError ("fib: negative index: " ++ stringify value))
    | otherwise -> pure (truncate num)

-- | The nth Fibonacci number: fib(0)=0, fib(1)=1.
fibnum :: Int -> Integer
fibnum index
  | 0 == index = 0
  | otherwise = step 1 0 1
  where
    step at prev cur = if at >= index then cur else step (at + 1) cur (prev + cur)

fib :: Json -> IO Json
fib value = do
  index <- fibindex value
  pure (Num (fromIntegral (fibnum index)))

-- | The first n Fibonacci numbers.
fibseq :: Json -> IO Json
fibseq value = do
  count <- fibindex value
  pure (JList [Num (fromIntegral (fibnum index)) | index <- [0 .. count - 1]])

-- | The Fibonacci numbers from index start to index end, inclusive.
fibrange :: Json -> Json -> IO Json
fibrange start stop = do
  from <- fibindex start
  upto <- fibindex stop
  pure (JList [Num (fromIntegral (fibnum index)) | index <- [from .. upto]])

-- | A description of the nth Fibonacci number. `prev` is null at index 0,
-- which exercises the runner's null handling.
fibinfo :: Json -> IO Json
fibinfo value = do
  index <- fibindex value
  let num = fibnum index

  pure
    ( JMap
        [ ("n", Num (fromIntegral index)),
          ("val", Num (fromIntegral num)),
          ("even", Bool (0 == num `mod` 2)),
          ("prev", if 0 == index then Null else Num (fromIntegral (fibnum (index - 1)))),
          ( "label",
            Str ("fib(" ++ numstr (fromIntegral index) ++ ")=" ++ numstr (fromIntegral num))
          )
        ]
    )
