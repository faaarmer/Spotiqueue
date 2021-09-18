;;; BEGIN paul-config.scm
;;;
;;; Copyright © 2021 paul at denknerd dot org
;;;
;;; This is an example of what would live in a user's config.  It is in fact the actual thing i use
;;; at the moment, i have a symlink:
;;;
;;; ~/.config/spotiqueue/init.scm -> ~/src/Spotiqueue/examples/paul-config.scm.
;;;
;;; I hope to use this file to collect a few neat ideas of things you can customise using the Guile
;;; bindings provided by Spotiqueue.
(use-modules (ice-9 textual-ports)
             (ice-9 format)
             (ice-9 popen)
             (ice-9 receive)
             (srfi srfi-9 gnu)
             (texinfo string-utils))
(use-modules (spotiqueue records))
(format #t "guile ~s: Loading paul's config.~%" (module-name (current-module)))

(set-record-type-printer! <track>
                          (lambda (record port)
                            (format port
                                    "~a ~a - ~a (~a)"
                                    (track-uri record)
                                    (track-artist record)
                                    (track-title record)
                                    (track-album record))))

(define (paul:formatted-time)
  (strftime "[%a %e/%b/%Y %H:%M:%S %Z]" (localtime (current-time))))

(define* (write-text path text #:key (append #f))
  (let ((file (open-file path (if append "a" "w"))))
    (put-string file text)
    (close-port file)))

(define my-homedir (getenv "HOME"))

(define (paul:player-started track)
  (if (not (track? track))
      (error "eek, not a track!"))
  (begin
    (format #t "hey, a track has started: ~s\n" track)
    (write-text
     (string-append my-homedir "/spotiqueue-played.txt")
     (format #f "~a ~a\n" (paul:formatted-time) track)
     #:append #t)))

(define (paul:player-endoftrack track)
  (if (not (track? track))
      (error "eek, not a track!"))
  (begin
    (format #t "end of track: ~s~%" track)))

(define (paul:paused)
  (display "guile: Paused.\n"))

(define (paul:unpaused)
  (display "guile: Resumed/Unpaused.\n"))

(reset-hook! player-endoftrack-hook)
(reset-hook! player-paused-hook)
(reset-hook! player-started-hook)
(reset-hook! player-unpaused-hook)
(add-hook! player-endoftrack-hook paul:player-endoftrack)
(add-hook! player-paused-hook paul:paused)
(add-hook! player-started-hook paul:player-started)
(add-hook! player-unpaused-hook paul:unpaused)

;; Unbind a key i don't like, as an example:
(define-key queue-panel-map (kbd 'ForwardDelete) #nil)

;; Don't do this!
;; TODO run hooks on a background thread.
;; (add-hook! selection-copied-hook (lambda (itms) (sleep 5)))

(add-hook! selection-copied-hook
           (lambda (itms)
             (begin
               (let* ((message (format #f
                                       "💿 Copied ~r item~:p 🎧"
                                       (length itms)))
                      ;; Okay it's not great but i'm escaping quotes so that it remains valid Lua code...
                      (hs-alert (format #f "hs.alert.show(\"~a\")" (escape-special-chars message #\" #\\)))
                      (commands `(("/usr/local/bin/hs" "-c" ,hs-alert))))
                 (format #t "~a~%" message)
                 (receive (from to pids) (pipeline commands)
                   (close to)
                   (close from))))))

;; TODO (window:maximise) ; to fill screen

(use-modules (system repl server))
(with-exception-handler
    (lambda (exn) (display "Couldn't bind port, skipping.\n"))
  (lambda ()
    (spawn-server (make-tcp-server-socket))) ; loopback:37146 by default
  #:unwind? #t)

(format #t "Yay, unicode works 😊 📼 ~%")

;;; END paul-config.scm
