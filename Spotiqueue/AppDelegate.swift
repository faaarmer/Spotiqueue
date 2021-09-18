//
//  AppDelegate.swift
//  Spotiqueue
//
//  Created by Paul on 18/5/21.
//  Copyright © 2021 Rustling Broccoli. All rights reserved.
//

import AppMover
import Cocoa
import Combine
import Sparkle
import SpotifyWebAPI
import Stenographer

#if DEBUG
let minimumLogPriorityLevel: SXPriorityLevel = .all
#else
let minimumLogPriorityLevel: SXPriorityLevel = .warning
#endif

let logger = SXLogger(endpoints: [
    SXConsoleEndpoint(minimumPriorityLevel: minimumLogPriorityLevel)
])

@_cdecl("player_update_hook")
public func player_update_hook(hook: StatusUpdate, position_ms: UInt32, duration_ms: UInt32) {
    logger.info("Hook spotiqueue-worker hook ==> \(hook.rawValue)")
    switch hook {
        case EndOfTrack:
            // We can't call end_of_track to Scheme inside the async / main-thread block, because we can't be sure when it'll be run, and want to grab the current track before it's obliterated by the "stopped" signal which comes right after the EndOfTrack signal.
            DispatchQueue.main.async{
                AppDelegate.appDelegate().playerState = .Stopped
                AppDelegate.appDelegate().position = 0
                AppDelegate.appDelegate().duration = 0
                AppDelegate.appDelegate().endOfTrack() // Fire off Guile hook.
                if AppDelegate.appDelegate().shouldAutoAdvance() {
                    _ = AppDelegate.appDelegate().playNextQueuedTrack()
                }
            }
        case Paused:
            DispatchQueue.main.async{
                AppDelegate.appDelegate().playerState = .Paused
                AppDelegate.appDelegate().position = Double(position_ms/1000)
                AppDelegate.appDelegate().duration = Double(duration_ms/1000)
            }
        case Playing:
            DispatchQueue.main.async{
                AppDelegate.appDelegate().playerState = .Playing
                AppDelegate.appDelegate().position = Double(position_ms/1000)
                AppDelegate.appDelegate().duration = Double(duration_ms/1000)
            }
        case Stopped:
            DispatchQueue.main.async{
                AppDelegate.appDelegate().playerState = .Stopped
                // Okay, it seems we get the "stop" signal from a previous track, like, halfway through the next one.  This is a bit confusing.  We could pass along the request_id, which seems to increment, and ignore "previous tracks'" stop signals.  Ugh.  You know what, probably nobody will use this anyway.
                // In fact, come to think of it, maybe we should fully ditch the Stopped signal, and pretend that the only way to stop is by EndOfTrack/Pause.  A "full" stop is simply an EndOfTrack which is never followed by a Playing signal.
                AppDelegate.appDelegate().position = 0
                AppDelegate.appDelegate().duration = 0
            }
        case TimeToPreloadNextTrack:
            DispatchQueue.main.async{
                AppDelegate.appDelegate().preloadNextQueuedTrack()
            }
        default:
            fatalError("Received absurd hook.")
    }
}

enum PlayerState {
    case Stopped
    case Playing
    case Paused
}

enum SearchCommand {
    case Freetext(String)
    case Album(Album)
    case Artist(Artist)
    case AllPlaylists
    case Playlist(String, SpotifyURIConvertible)
}

class AppDelegate: NSObject, NSApplicationDelegate {

    @IBAction func checkForUpdates(_ sender: Any) {
        sparkle.checkForUpdates(sender)
    }

    @IBOutlet weak var queueTableView: RBQueueTableView!
    @IBOutlet weak var searchTableView: RBSearchTableView!
    @IBOutlet weak var searchField: NSSearchField!
    @IBOutlet weak var searchFieldCell: NSSearchFieldCell!
    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var searchResultsArrayController: NSArrayController!
    @IBOutlet weak var queueArrayController: NSArrayController!
    @IBOutlet weak var searchLabel: NSTextField!

    @objc dynamic var searchResults: Array<RBSpotifyTrack> = []
    @objc dynamic var queue: Array<RBSpotifyTrack> = []

    // MARK: View element bindings
    @IBOutlet weak var queueHeaderLabel: NSTextField!
    @IBOutlet weak var albumImage: NSImageView!
    @IBOutlet weak var albumTitleLabel: NSTextField!
    @IBOutlet weak var trackTitleLabel: NSTextField!
    @IBOutlet weak var durationLabel: NSTextField!
    @IBOutlet weak var autoAdvanceButton: NSButton!
    @IBOutlet weak var searchSpinner: NSProgressIndicator!
    @IBOutlet weak var progressBar: NSProgressIndicator!
    @IBOutlet weak var filterResultsField: RBFilterField!

    var playerState: PlayerState = .Stopped
    var searchHistory: [SearchCommand] = [] {
        didSet {
            if let history = searchHistory.last {
                switch history {
                    case .Freetext(let searchText):
                        searchLabel.stringValue = "Search: “\(searchText)”"
                    case .Album(let album):
                        searchLabel.stringValue = "Album: “\(album.name)”"
                    case .Artist(let artist):
                        searchLabel.stringValue = "Artist: “\(artist.name)”"
                    case .AllPlaylists:
                        searchLabel.stringValue = "User Playlists"
                    case .Playlist(let title, _):
                        searchLabel.stringValue = "Playlist: “\(title)”"
                }
            } else {
                searchLabel.stringValue = "Search Results"
            }
        }
    }

    var loginWindow: RBLoginWindow?

    let sparkle: SUUpdater = SUUpdater(for: Bundle.main)

    var isSearching: Bool = false {
        didSet {
            if isSearching {
                logger.info("Commenced 'isSearching' spinner...")
                self.searchSpinner.isHidden = false
                self.searchSpinner.startAnimation(self)
                self.searchField.isEnabled = false
            } else {
                self.searchSpinner.isHidden = true
                self.searchSpinner.stopAnimation(self)
                self.searchField.isEnabled = true
                logger.info("Finished 'isSearching' spinner...")
            }
        }
    }

    func shouldAutoAdvance() -> Bool {
        let but = AppDelegate.appDelegate().autoAdvanceButton
        return but?.state == .on
    }

    var position: TimeInterval = 0
    var duration: TimeInterval = 0

    func updateDurationDisplay() {
        let remaining = round(duration) - round(position)
        durationLabel.cell?.title = String(format: "%@ / -%@ / %@",
                                           round(position).positionalTime,
                                           round(remaining).positionalTime,
                                           round(duration).positionalTime)
        progressBar.isHidden = duration == 0
        progressBar.doubleValue = 100 * position/duration
    }

    // MARK: Button action bindings

    @IBAction func nextTrackButtonPressed(_ sender: Any) {
        _ = self.playNextQueuedTrack()
    }

    @IBAction func filterFieldAction(_ sender: Any) {
        self.window.makeFirstResponder(self.searchTableView)
        if self.searchTableView.selectedRowIndexes.isEmpty {
            self.searchTableView.selectRow(row: 0)
        }
    }

    var spotify: RBSpotifyAPI = RBSpotifyAPI()
    @objc dynamic var currentTrack: RBSpotifyTrack?

    @IBAction func findCurrentTrackAlbum(_ sender: Any) {
        guard let track = self.currentTrack else { return }
        self.browseDetails(for: track, consideringHistory: false)
    }

    private var cancellables: Set<AnyCancellable> = []

    // Hooking up the Array Controller it was helpful to read https://swiftrien.blogspot.com/2015/11/swift-example-binding-nstableview-to.html
    // I also had to follow advice here https://stackoverflow.com/questions/46756535/xcode-cannot-resolve-the-entered-path-when-binding-control-in-xib-file because apparently in newer Swift, @objc dynamic isn't implied.
    // Here is another extensive howto around table views and such https://www.raywenderlich.com/921-cocoa-bindings-on-macos

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        loginWindow = RBLoginWindow(windowNibName: "RBLoginWindow")
        if let window = loginWindow?.window {
            self.window?.beginSheet(window, completionHandler: { [self] response in
                self.initialiseSpotifyWebAPI()
                self.loginWindow = nil
            })
            loginWindow?.startLoginRoutine()
        } else {
            // Mind you, this will be nil if AppMover moves the executable away before we have had a chance to load the NIB.  Which is still a file...
            logger.critical("Something very weird - modal.window is nil!")
        }
        set_callback(player_update_hook(hook: position_ms: duration_ms:))
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown /*, .systemDefined */], handler: localKeyShortcuts(event:))

        queueArrayController.selectsInsertedObjects = false
        searchResultsArrayController.selectsInsertedObjects = false

        let timerInterval : TimeInterval = 0.25
        Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] timer in
            if let s = self {
                if s.playerState == .Playing {
                    s.position += timerInterval
                }
                s.updateDurationDisplay()
            }
        }

        self.addObserver(self, forKeyPath: "queueArrayController.arrangedObjects", options: .new, context: nil)
        self.addObserver(self, forKeyPath: "searchResultsArrayController.arrangedObjects", options: [.initial, .new], context: nil)

        // setup "focus loop" / tab order
        self.window.initialFirstResponder = self.searchField
        self.searchField.nextKeyView = self.searchTableView
        self.searchTableView.nextKeyView = self.queueTableView
        self.queueTableView.nextKeyView = self.searchField
        self.window.makeFirstResponder(self.searchField)

        // I choose to check whether we're authorised here, because if we aren't pasting will result in a bunch of ugly URI entries in the queue.  They work, but meh.  The way around this would be to observe the auth-state of self.spotify, and only try loading the queue from UserDefaults at that point, but honestly having a queue saved but not being authorised is a bit of an edge-case.  Queue isn't valuable, you can rebuild it or save it in a playlist if you really care to.
        if self.spotify.isAuthorized,
           let savedQueuedTracks = UserDefaults.standard.string(forKey: "queuedTracks") {
            self.queueTableView.addTracksToQueue(from: savedQueuedTracks)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }

        if keyPath == "queueArrayController.arrangedObjects" {
            // sum up the durations and put the info into the queue heading label
            if let queueTracks = queueArrayController.arrangedObjects as? [RBSpotifyTrack] {
                let totalLengthSeconds = queueTracks.map(\.durationSeconds).reduce(0, +)
                if totalLengthSeconds > 0 {
                    queueHeaderLabel.stringValue = String(format: "Queue (%@ total)", totalLengthSeconds.positionalTime)
                } else {
                    queueHeaderLabel.stringValue = "Queue"
                }
                let nrResultsAppendix = String(format: "(%@ items)", self.queue.isEmpty ? "no" : String(self.queue.count))
                queueTableView.tableColumns.first?.title = "Title \(nrResultsAppendix)"
            } else {
                logger.info("\(keyPath): \(String(describing: change))")
            }
        } else if keyPath == "searchResultsArrayController.arrangedObjects" {
            var nrResultsAppendix: String = ""
            if self.searchResults.count > 0 {
                if !self.filterResultsField.stringValue.isEmpty,
                   let filtered = self.searchResultsArrayController.arrangedObjects as? Array<RBSpotifyTrack> {
                    // There's a filter applied; let's show match count.
                    nrResultsAppendix = "(\(filtered.count) / \(self.searchResults.count) items)"
                } else {
                    nrResultsAppendix = "(\(self.searchResults.count) items)"
                }
            } else {
                nrResultsAppendix = "(no items)"
            }

            searchTableView.tableColumns.first?.title = "Title \(nrResultsAppendix)"
        }
    }
    
    func focusSearchBox() {
        self.window.makeFirstResponder(searchField)
    }

    func localKeyShortcuts(event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])

        if RBGuileBridge.guile_handle_key(map: .global,
                                          keycode: event.keyCode,
                                          control: flags.contains(.control),
                                          command: flags.contains(.command),
                                          alt: flags.contains(.option),
                                          shift: flags.contains(.shift)) {
            // If a key is bound in a Guile script, that takes precedence, so we want to bail out here.  Otherwise, continue and execute the default "hard-coded" keybindings.
            return nil
        }

        if flags == .command
            && event.characters == "f" {
            self.focusSearchBox()
        } else if flags == .command
                    && event.characters == "l" {
            self.focusSearchBox()
        } else if flags == .command
                    && event.characters == "q" {
            for window in NSApp.windows {
                window.close()
            }
            NSApp.terminate(self)
        } else if flags == .command
                    && event.characters == "o" {
            retrieveAllPlaylists()
        } else if flags.isEmpty
                    && event.keyCode == kVK_Escape
                    && self.window.sheets.isEmpty // we don't want Esc eaten up if a modal is displayed
        {
            if (self.window.firstResponder == self.searchTableView && !self.isSearching)
                || self.window.firstResponder == self.filterResultsField.currentEditor() {
                // Esc should probably cancel the local filtering, too.
                self.filterResultsField.clearFilter()
                self.searchTableView.scrollRowToVisible(self.searchTableView.selectedRow)
                self.window.makeFirstResponder(self.searchTableView)
            } else {
                cancellables.forEach { $0.cancel() }
                self.isSearching = false
            }
        } else if flags.isEmpty
                    && event.keyCode == kVK_Tab
                    && self.window.firstResponder == self.filterResultsField.currentEditor() {
            self.focusSearchBox()
        } else {
            return event
        }
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if self.queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: "queuedTracks")
        } else {
            let queuedTracks: String = self.queue.map { $0.copyTextTrack() }.joined(separator: "\n")
            UserDefaults.standard.set(queuedTracks, forKey: "queuedTracks")
            logger.info("Saved queued tracks.")
        }
        UserDefaults.standard.synchronize()
        return .terminateNow
    }

    // from https://stackoverflow.com/questions/1991072/how-to-handle-with-a-default-url-scheme
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        AppMover.moveIfNecessary()
        #endif
        self.searchHistory = [] // empty history.  side-effect: update search label... :/
        NSAppleEventManager
            .shared()
            .setEventHandler(
                self,
                andSelector: #selector(handleURL(event:reply:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
    }

    @objc func handleURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue?.removingPercentEncoding {
            if url.hasPrefix(RBSpotifyAPI.loginCallbackURL.description) {
                logger.info("received redirect from Spotify: '\(url)'")
                // This property is used to display an activity indicator in
                // `LoginView` indicating that the access and refresh tokens
                // are being retrieved.
                spotify.isRetrievingTokens = true

                // Complete the authorization process by requesting the
                // access and refresh tokens.
                spotify.api.authorizationManager.requestAccessAndRefreshTokens(
                    redirectURIWithQuery: URL(string: url)!,
                    codeVerifier: RBSpotifyAPI.codeVerifier,
                    // This value must be the same as the one used to create the
                    // authorization URL. Otherwise, an error will be thrown.
                    state: spotify.authorizationState
                )
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    // Whether the request succeeded or not, we need to remove
                    // the activity indicator.
                    self.spotify.isRetrievingTokens = false

                    /*
                     After the access and refresh tokens are retrieved,
                     `SpotifyAPI.authorizationManagerDidChange` will emit a
                     signal, causing `Spotify.handleChangesToAuthorizationManager()`
                     to be called, which will dismiss the loginView if the app was
                     successfully authorized by setting the
                     @Published `Spotify.isAuthorized` property to `true`.

                     The only thing we need to do here is handle the error and
                     show it to the user if one was received.
                     */
                    switch completion {
                    case .failure(let error):
                        logger.error("couldn't retrieve access and refresh tokens:\n\(error)")
                        if let authError = error as? SpotifyAuthorizationError,
                           authError.accessWasDenied {
                            logger.error("Authorisation request denied!")
                            let alert = NSAlert.init()
                            alert.messageText = "Authorisation denied!"
                            alert.informativeText = "Authorisation request denied."
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                        else {
                            logger.error("Couldn't authorise: \(error.localizedDescription)")
                            let alert = NSAlert.init()
                            alert.messageText = "Authorisation failed!"
                            alert.informativeText = "Authorisation request failed: \(error.localizedDescription)"
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    case .finished:
                        logger.info("Successfully received tokens from Spotify.")
                        let alert = NSAlert.init()
                        alert.messageText = "Authorised"
                        alert.informativeText = "Successfully authorised with Spotify.  You can safely close the web browser window."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                })
                .store(in: &cancellables)

                // MARK: IMPORTANT: generate a new value for the state parameter
                // MARK: after each authorization request. This ensures an incoming
                // MARK: redirect from Spotify was the result of a request made by
                // MARK: this app, and not an attacker.
                self.spotify.authorizationState = String.randomURLSafe(length: 128)
            } else {
                logger.error("not handling URL: unexpected scheme: '\(url)'")
            }
        }
    }

    func retrieveAllPlaylists() {
        guard !self.isSearching else {
            return
        }
        self.isSearching = true

        searchResults = []
        self.filterResultsField.clearFilter()
        searchResultsArrayController.sortDescriptors = []
        searchHistory.append(.AllPlaylists)

        spotify.api.currentUserPlaylists()
            .extendPagesConcurrently(spotify.api)
            .collectAndSortByOffset()
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                self.isSearching = false
                if case .failure(let error) = completion {
                    logger.error("couldn't retrieve playlists: \(error.localizedDescription)")
                }
            }
            , receiveValue: { playlists in
                for pl in playlists {
                    self.searchResults.append(RBSpotifyTrack(playlist: pl))
                }
                self.searchTableView.selectRow(row: 0)
            })
            .store(in: &cancellables)

        self.window.makeFirstResponder(searchTableView)
    }

    func browseDetails(for row: RBSpotifyTrack, consideringHistory: Bool = true) {
        guard !self.isSearching else {
            return
        }
        self.isSearching = true
        searchResults = []
        self.filterResultsField.clearFilter()
        self.window.makeFirstResponder(searchTableView)

        if let history = searchHistory.last, consideringHistory {
            switch history {
                case .Freetext:
                    albumTracks(for: row.spotify_album)
                case .Album:
                    artistTracks(for: row.spotify_artist)
                case .Artist:
                    albumTracks(for: row.spotify_album)
                case .AllPlaylists:
                    searchPlaylistTracks(for: row.spotify_uri, withTitle: row.title)
                case .Playlist:
                    albumTracks(for: row.spotify_album)
            }
        } else {
            // The default case.
            albumTracks(for: row.spotify_album)
        }
    }

    private func searchPlaylistTracks(for playlist_uri: String?, withTitle title: String) {
        guard let playlist_uri = playlist_uri else {
            logger.warning("Called with nil playlist URI!  Doing nothing.")
            return
        }

        // okay, so listing a playlist's tracks isn't strictly a free-text search, but mainly we use that to tell Spotiqueue that a followup "detail-browse" should get the album for a track, and the one after that should get the artist's entire library.
        searchHistory.append(.Playlist(title, playlist_uri))
        searchResultsArrayController.sortDescriptors = []

        loadPlaylistTracksInto(for: playlist_uri, in: .Search)
    }

    enum TrackList {
        case Queue
        case Search
    }

    func loadPlaylistTracksInto(for playlist_uri: String?,
                                in target: TrackList,
                                at_the_top: Bool = false,
                                and_then_advance: Bool = false) {
        guard let playlist_uri = playlist_uri else {
            logger.warning("Called with nil playlist URI!  Doing nothing.")
            return
        }

        spotify.api.playlistItems(playlist_uri)
            .extendPagesConcurrently(spotify.api)
            .collectAndSortByOffset()
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: {completion in
                self.isSearching = false
                switch completion {
                    case .finished:
                        logger.info("finished loading playlist")
                    case .failure(let error):
                        logger.error("Couldn't load playlist: \(error.localizedDescription)")
                }
            },
            receiveValue: { items in
                var newRows: Array<RBSpotifyTrack> = []
                for playlistItemContainer in items {
                    if case .track(let track) = playlistItemContainer.item {
                        newRows.append(RBSpotifyTrack.init(track: track))
                    }
                }
                self.insertTracks(newRows: newRows,
                                  in: target,
                                  at_the_top: at_the_top,
                                  and_then_advance: and_then_advance)
            })
            .store(in: &cancellables)
    }

    func insertTracks(newRows: Array<RBSpotifyTrack>,
                      in target: TrackList,
                      at_the_top: Bool = false,
                      and_then_advance: Bool = false) {
        switch target {
        case .Queue:
            let position = at_the_top ? 0 : self.queue.count
            self.queue.insert(contentsOf: newRows, at: position)
            self.queueTableView.selectRow(row: position)
        case .Search:
            let position = at_the_top ? 0 : self.searchResults.count
            self.searchResults.insert(contentsOf: newRows, at: position)
            self.searchTableView.selectRow(row: position)
        }

        if and_then_advance {
            _ = self.playNextQueuedTrack()
        }
    }

    func albumTracks(for album: Album?) {
        guard let album = album else {
            logger.warning("Called with nil album!  Doing nothing.")
            return
        }

        searchHistory.append(.Album(album))
        // retrieve album tracks
        spotify.api.albumTracks(
            album.uri!,
            limit: 50)
            .extendPages(spotify.api)
            .receive(on: RunLoop.main)
            .sink(
                receiveCompletion: { completion in
                    self.isSearching = false
                    switch completion {
                        case .finished:
                            logger.info("finished loading album object")
                            // If there is a self.currentTrack and it's on the just-found album, let's highlight that track.
                            if let current_track = self.currentTrack, current_track.album_uri == album.uri {
                                logger.info("What a coincidence, we're browsing the album of the currently-playing track.")
                                if let idx = self.searchResults.firstIndex(where: { sItem in
                                    sItem.spotify_uri == current_track.spotify_uri
                                }) {
                                    self.searchTableView.selectRow(row: idx)
                                }
                            }
                        case .failure(let error):
                            logger.error("Couldn't load album: \(error.localizedDescription)")
                    }
                },
                receiveValue: { tracksPage in
                    let simplifiedTracks = tracksPage.items
                    // create a new array of table rows from the page of simplified tracks
                    let newTableRows = simplifiedTracks.map { t in
                        RBSpotifyTrack.init(track: t, album: album, artist: t.artists!.first!)
                    }
                    // append the new table rows to the full array
                    self.searchResults.append(contentsOf: newTableRows)
                }
            )
            .store(in: &cancellables)
    }

    var runningTasks: Int = 0 {
        didSet {
            if runningTasks == 0 {
                self.isSearching = false
            }
        }
    }

    private func artistTracks(for artist: Artist?) {
        guard let artist = artist else {
            logger.warning("Called with nil artist!  Doing nothing.")
            return
        }

        searchHistory.append(.Artist(artist))
        let dispatchGroup = DispatchGroup()

        var albumsReceived: [Album] = []
        dispatchGroup.enter()
        spotify.api.artistFullAlbums(artist.uri!)
            .sink(
                receiveCompletion: { completion in
                    switch completion {
                        case .finished:
                            logger.info("finished loading artists' albums")
                        case .failure(let error):
                            logger.error("Couldn't load artist's albums: \(error.localizedDescription)")
                    }
                    dispatchGroup.leave()
                },
                receiveValue: { albums in
                    albumsReceived += albums
                }
            )
            .store(in: &cancellables)

        dispatchGroup.notify(queue: .main) {
            self.runningTasks = albumsReceived.count
            for album in albumsReceived {
                self.spotify.api.albumTracks(album.uri!, limit: 50)
                    .extendPagesConcurrently(self.spotify.api)
                    .receive(on: RunLoop.main)
                    .sink(receiveCompletion: { [self] completion in
                        runningTasks -= 1
                        switch completion {
                            case .finished:
                                logger.info("finished loading tracks for album \(album.name)")
                            case .failure(let error):
                                logger.error("Couldn't load album's tracks: \(error.localizedDescription)")
                        }
                    },
                    receiveValue: { tracksPage in
                        let simplifiedTracks = tracksPage.items
                        // create a new array of table rows from the page of simplified tracks
                        let newTableRows = simplifiedTracks.map{ t in
                            RBSpotifyTrack.init(track: t, album: album, artist: artist)
                        }
                        // append the new table rows to the full array
                        self.searchResults.append(contentsOf: newTableRows)
                        // after finishing we want the cursor at the top. however, the "streaming" results means some newer albums might have showed up later, pushing your selection down.
                        self.searchTableView.selectRow(row: 0)
                    }
                    )
                    .store(in: &self.cancellables)
            }
        }
    }

    @IBAction func search(_ sender: NSSearchField) {
        guard !self.isSearching else {
            return
        }

        let searchString = self.searchFieldCell.stringValue
        if searchString.isEmpty {
            return
        }
        self.isSearching = true
        logger.info("Searching for \"\(searchString)\"...")

        searchResults = []
        self.filterResultsField.clearFilter()
        searchHistory.append(.Freetext(searchString))

        // cheap and dirty way of saying "this many pages expected"
        runningTasks = 4
        for i in 0..<runningTasks {
            spotify.api.search(
                query: searchString,
                categories: [.track],
                limit: 50,
                offset: i * 50
            )
            .receive(on: RunLoop.main)
            .sink(
                receiveCompletion: { [self] completion in
                    runningTasks -= 1
                    if case .failure(let error) = completion {
                        logger.error("Couldn't perform search:")
                        logger.error(error.localizedDescription)
                    }
                },
                receiveValue: { [self] searchResultsReturn in
                    for result in searchResultsReturn.tracks?.items ?? [] {
                        searchResults.append(RBSpotifyTrack(track: result))
                    }
                    logger.info("[query \(i)] Received \(self.searchResults.count) tracks")
                    searchResultsArrayController.sortDescriptors = RBSpotifyTrack.trackSortDescriptors
                    searchResultsArrayController.rearrangeObjects()
                    searchTableView.selectRow(row: 0)
                }
            )
            .store(in: &cancellables)
        }
        self.window.makeFirstResponder(searchTableView)
    }

    func initialiseSpotifyWebAPI() {
        if !spotify.isAuthorized {
            spotify.authorize()
        }
    }

    @IBAction func playOrPause(_ sender: Any) {
        switch self.playerState {
            case .Stopped:
                return
            case .Playing:
                RBGuileBridge.player_paused_hook()
                spotiqueue_pause_playback()
            case .Paused:
                RBGuileBridge.player_unpaused_hook()
                spotiqueue_unpause_playback()
        }
    }

    func endOfTrack() {
        guard let previousTrack = self.currentTrack else {
            logger.error("AppDelegate.endOfTrack called but self.currentTrack == nil!")
            return
        }
        RBGuileBridge.player_endoftrack_hook(track: previousTrack)
    }

    func playNextQueuedTrack() -> Bool {
        guard let nextTrack = queue.first else {
            return false
        }
        self.currentTrack = nextTrack
        spotiqueue_play_track(self.currentTrack!.spotify_uri)
        RBGuileBridge.player_playing_hook(track: self.currentTrack!)
        self.albumTitleLabel.cell?.title = nextTrack.album
        self.trackTitleLabel.cell?.title = nextTrack.prettyArtistDashTitle()

        // ehm awkward, attempting to get second largest image.
        if let image = nextTrack.album_image {
            self.albumImage.imageFromServerURL(image.url.absoluteString, placeHolder: nil)
        }
        queue.remove(at: 0)
        return true
    }

    func preloadNextQueuedTrack() {
        guard let nextTrack = queue.first else {
            return
        }
        spotiqueue_preload_track(nextTrack.spotify_uri)
    }

    // Helper to give me a pointer to this AppDelegate object.
    static func appDelegate() -> AppDelegate {
        return NSApplication.shared.delegate as! AppDelegate
    }
}
