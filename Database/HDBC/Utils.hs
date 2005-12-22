-- #hide
{-
Copyright (C) 2005 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and\/or modify
it under the terms of the GNU Lesser General Public License as published by
the Free Software Foundation; either version 2.1 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

-}

{- |
   Module     : Database.HDBC.Utils
   Copyright  : Copyright (C) 2005 John Goerzen
   License    : GNU LGPL, version 2 or above

   Maintainer : John Goerzen <jgoerzen@complete.org>
   Stability  : provisional
   Portability: portable

Internal module -- not exported directly.

Everything in here is expoerted by "Database.HDBC".  Please use -- and read --
"Database.HDBC" directly.

Written by John Goerzen, jgoerzen\@complete.org
-}

module Database.HDBC.Utils where
import Database.HDBC.Types
import Control.Exception
import Data.Dynamic
import System.IO.Unsafe

{- | Execute the given IO action.

If it raises a 'SqlError', then execute the supplied handler and return its
return value.  Otherwise, proceed as normal. -}
catchSql :: IO a -> (SqlError -> IO a) -> IO a
catchSql = catchDyn

{- | Like 'catchSql', with the order of arguments reversed. -}
handleSql :: (SqlError -> IO a) -> IO a -> IO a
handleSql h f = catchDyn f h

{- | Given an Exception, return Just SqlError if it was an SqlError, or Nothing
otherwise. Useful with functions like catchJust. -}
sqlExceptions :: Exception -> Maybe SqlError
sqlExceptions e = dynExceptions e >>= fromDynamic

{- | Catches 'SqlError's, and re-raises them as IO errors with fail.
Useful if you don't care to catch SQL errors, but want to see a sane
error message if one happens.  One would often use this as a high-level
wrapper around SQL calls. -}
handleSqlError :: IO a -> IO a
handleSqlError action =
    catchSql action handler
    where handler e = fail ("SQL error: " ++ show e)

{- | Like 'run', but take a list of Maybe Strings instead of 'SqlValue's. -}
sRun :: Connection -> String -> [Maybe String] -> IO Integer
sRun conn qry lst =
    run conn qry (map toSql lst)

{- | Like 'execute', but take a list of Maybe Strings instead of
   'SqlValue's. -}
sExecute :: Statement -> [Maybe String] -> IO Integer
sExecute sth lst = execute sth (map toSql lst)

{- | Like 'executeMany', but take a list of Maybe Strings instead of
   'SqlValue's. -}
sExecuteMany :: Statement -> [[Maybe String]] -> IO Integer
sExecuteMany sth lst = 
    executeMany sth (map (map toSql) lst)

{- | Like 'fetchRow', but return a list of Maybe Strings instead of
   'SqlValue's. -}
sFetchRow :: Statement -> IO (Maybe [Maybe String])
sFetchRow sth =
    do res <- fetchRow sth
       case res of
         Nothing -> return Nothing
         Just x -> return $ Just $ map fromSql x

{- | Execute some code.  If any uncaught exception occurs, run
'rollback' and re-raise it.  Otherwise, run 'commit' and return.

This function, therefore, encapsulates the logical property that a transaction
is all about: all or nothing.

The 'Connection' object passed in is passed directly to the specified
function as a convenience.

This function traps /all/ uncaught exceptions, not just SqlErrors.  Therefore,
you will get a rollback for any exception that you don't handle.  That's
probably what you want anyway.

Since all operations in HDBC are done in a transaction, this function doesn't
issue an explicit \"begin\" to the server.  You should ideally have
called 'Database.HDBC.commit' or 'Database.HDBC.rollback' before
calling this function.  If you haven't, this function will commit or rollback
more than just the changes made in the included action.

If there was an error while running 'rollback', this error will not be
reported since the original exception will be propogated back.  (You'd probably
like to know about the root cause for all of this anyway.)  Feedback
on this behavior is solicited.
-}
withTransaction :: Connection -> (Connection -> IO a) -> IO a
withTransaction conn func =
    do r <- try (func conn)
       case r of
         Right x -> do commit conn
                       return x
         Left e -> 
             do try (rollback conn) -- Discard any exception here
                throw e

{- | Lazily fetch all rows from an executed 'Statement'.

You can think of this as hGetContents applied to a database result set.

The result of this is a lazy list, and each new row will be read, lazily, from
the database as the list is processed.

When you have exhausted the list, the 'Statement' will be 'finish'ed.

Please note that the careless use of this function can lead to some unpleasant
behavior.  In particular, if you have not consumed the entire list, then
attempt to 'finish' or re-execute the statement, and then attempt to consume
more elements from the list, the result will almost certainly not be what
you want.

But then, similar caveats apply with hGetContents.

Bottom line: this is a very convenient abstraction; use it wisely.
-}
fetchAllRows :: Statement -> IO [[SqlValue]]
fetchAllRows sth = unsafeInterleaveIO $
    do row <- fetchRow sth
       case row of
         Nothing -> return []
         Just x -> do remainder <- fetchAllRows sth
                      return (x : remainder)

{- | Like 'fetchAllRows', but return Maybe Strings instead of 'SqlValue's. -}
sFetchAllRows :: Statement -> IO [[Maybe String]]
sFetchAllRows sth =
    do res <- fetchAllRows sth
       return $ map (map fromSql) res