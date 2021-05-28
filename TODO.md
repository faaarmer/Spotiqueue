# Feature parity with the old thing


Remaining:
-   Use arrows to navigate around lists (maybe using shift to select stuff).
-   Holding the command-key and using the navigation keys moves the selected tracks in the queue.
-   Space bar pauses and unpauses (unless search field has focus).
-   ⌘← enqueues, ⌘⇧← adds tracks to top of queue.


# TODO list

* under high CPU load spotiqueue-worker seems to falter.

* preloading

* Automatically switch audio output sink when using Sound.prefpane
* [x] Album browse
* Artist browse
* Duration song countdown.. how? can/should we poll the worker every
  so often? maybe have to worker, when playing, ping the GUI every few
  seconds? just in case jitter happened or whatnot...

* Keep track of current playback status: playing/paused/stopped
* Play/pause with spacebar

* Copying and pasting of spotify URIs
* Dragging items position in queue
* Dragging items into queue from search

* Media keys, globally

# Ideas

* Keep track of last-searched: free-text, album, or artist, and if you've cmd-right'ed to get an album, doing it again gets the artist's tracks/albums?
* If doing album-browse, put "album:..." into the search bar?

* Search: if searching for "album:...URI..." plus a term, maybe filter results (locally) on those terms?

* shift-V switches "visual" mode, allow selecting rows in queue with
  motion keys?

* "d" deletes row from queue.



# Lower priority

* ...constraints? SwiftUI? ...?
* Better column widths in TableView 🙁

* Nicer login and auth flow.  Maybe use OAUTH for spotiqueue-worker, too.
* Save queue to .. NSUserDefaults? Text file?

* clean debug logs to be a bit more readable 😬

* Loved tracks retrieval
* Add/remove star

* All playlists retrieval
* Create playlist.. maybe?

* Figure out how to conditionally include release/debug version of spotiqueue-worker.


* Search: Does "album:asdf" make sense? Search for "asdf" in album titles?  why not _just_ search for "asdf"?  Maybe park that idea until it turns out i'm often failing to find what i'm after in one go.
