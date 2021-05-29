# Feature parity with the old thing


Remaining:
-   Holding the command-key and using the navigation keys moves the selected tracks in the queue.


# TODO list

* page up / down should bring focussed row along for the ride.

* under high CPU load spotiqueue-worker seems to falter.
  supposedly a release build will help...

* [x] preloading

* Automatically switch audio output sink when using Sound.prefpane
* [x] Album browse
* Artist browse
* [x] Duration song countdown

* [x] Keep track of current playback status: playing/paused/stopped
* [x] Play/pause with spacebar

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

* [x] "d" deletes row from queue.

* Some sort of local "filter results" function.  Press "/" or something?


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
