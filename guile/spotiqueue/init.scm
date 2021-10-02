;;; BEGIN init.scm
;;;
;;; Copyright © 2021 paul at denknerd dot org
;;;
;;; This file is read by Spotiqueue as soon as it starts up.  It exposes some helpers and hooks for
;;; users.

(format #t "%load-path = ~s\n" %load-path)

;; If i want to use this module naming scheme i should have the source files in a folder called
;; `spotiqueue'.  Grr, there are already so many of those i'll just nest the Scheme files in
;; guile/spotiqueue i guess.  The Copy Files phase in Xcode can sort that out.

(define-module (spotiqueue init)
  #:use-module (ice-9 format)
  #:use-module (spotiqueue internal)
  #:use-module (spotiqueue records)
  #:use-module (spotiqueue keybindings)
  #:declarative? #f)

(format #t "guile ~s: Loading Spotiqueue bootstrap config...~%" (module-name (current-module)))

;; Define the key maps
(define global-map (make-hash-table 10))
(define queue-panel-map (make-hash-table 10))
(define search-panel-map (make-hash-table 10))

;; Define the hooks.  The single argument is a <track> record.
(define player-started-hook (make-hook 1))
(define player-endoftrack-hook (make-hook 1))
(define player-paused-hook (make-hook 0))
(define player-unpaused-hook (make-hook 0))

;; The selection-copied hook will get a list of items copied as its single argument, each item
;; represented as string a (just as they'll end up on the pasteboard).
(define selection-copied-hook (make-hook 1))

;; TODO Check that arguments to define-key are reasonable.
(define (define-key map key action)
  (hash-set! map key action))

(define-key global-map (kbd 'ANSI_F #:cmd #t) 'window:focus-search-box)
(define-key global-map (kbd 'ANSI_L #:cmd #t) 'window:focus-search-box)

(define-key queue-panel-map (kbd 'ANSI_X)        'queue:delete-selected-tracks)
(define-key queue-panel-map (kbd 'ANSI_D)        'queue:delete-selected-tracks)
(define-key queue-panel-map (kbd 'Delete)        'queue:delete-selected-tracks)
(define-key queue-panel-map (kbd 'ForwardDelete) 'queue:delete-selected-tracks)

;; (define-key queue-panel-map (kbd 'ANSI_K #:cmd #t) 'queue:move-selected-tracks-up)

;;; END init.scm