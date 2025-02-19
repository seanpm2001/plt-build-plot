#lang racket/base
(require racket/system
         racket/file
         "plot.rkt"
         "upload.rkt"
         racket/future
         plt-service-monitor/beat)

(provide build)

(module+ main
  (require racket/cmdline)
  
  (define beat-bucket #f)
  (define log-verbose? #f)
  (define skip-clean? #f)
  (define src-catalog #f)
  (define variant #f)
  (define machine-independent? #f)
  (define no-gc? #f)
  (define racket #f)
  (define distro? #f)
  (define for-pkgs #f)
  (define available-plots '())

  (command-line
   #:once-each
   [("--beat") bucket "Record heartbeat at <bucket>"
    (set! beat-bucket bucket)]
   [("-v") "Log `raco setup -v`"
    (set! log-verbose? #t)]
   [("--skip-clean") "Skip the `git clean` step"
    (set! skip-clean? #t)]
   [("--catalog") catalog "Set the source catalog"
    (set! src-catalog catalog)]
   [("--variant") str "Choose a variant, such as `cs` or `bc`"
    (set! variant str)]
   [("-M") "Build to machine-independent bytecode"
    (set! machine-independent? #t)]
   [("--no-gc") "Disable GCs that are forced by `raco setup`"
    (set! no-gc? #t)]
   [("--racket") exec "Choose existing `racket` to drive the build"
    (set! racket exec)]
   [("--distro") "Build from a source distro instead of a Git checkout"
    (set! distro? #t)]
   [("--pkgs") pkgs "Build only <pkgs> instead of main-distribution"
    (set! for-pkgs pkgs)]
   [("--available") file "Read list of `(<desc> <url>)` from <file>"
    (define l (call-with-input-file* file read))
    (unless (and (list? l) (andmap (lambda (e) (and (list? e)
                                                    (= 2 (length e))
                                                    (string? (car e))
                                                    (string? (cadr e))))
                                   l))
      (raise-user-error 'plt-build-plot "ill-formed list of available plots in ~s" file))
    (set! available-plots l)]
   #:args
   ([bucket #f])
   (build bucket
          #:beat-bucket beat-bucket
          #:log-verbose? log-verbose?
          #:skip-clean? skip-clean?
          #:catalog src-catalog
          #:variant variant
          #:machine-independent? machine-independent?
          #:no-gc? no-gc?
          #:racket racket
          #:distro? distro?
          #:for-pkgs for-pkgs
          #:available-plots available-plots)))

(define (system! s)
  (printf "~a\n" s)
  (flush-output)
  (unless (system s)
    (error "failed")))

(define (build bucket
               #:log-verbose? [log-verbose? #f]
               #:skip-clean? [skip-clean? #f]
               #:work-dir [work-dir (current-directory)]
               #:variant [variant #f] ; can be "cs" or "bc"
               #:beat-bucket [beat-bucket #f]
               #:beat-task-name [beat-task-name (string-append
                                                 "build-plot"
                                                 (if variant
                                                     (string-append "-" variant)
                                                     ""))]
               #:catalog [src-catalog #f]
               #:machine-independent? [machine-independent? #f]
               #:no-gc? [no-gc? #f]
               #:racket [racket #f]  ; can be a path for RACKET=... to makefile
               #:distro? [distro? #f]
               #:for-pkgs [for-pkgs #f]
               #:available-plots [available-plots '()])
  (define (variant-of s)
    (if variant
        (string-append variant "-" s)
        s))
  (define config (string-append
                  (if racket
                      (format "RACKET=~a" racket)
                      "")
                  (if (equal? variant "cs")
                      " RACKETCS_SUFFIX="
                      "")
                  (if (equal? variant "bc")
                      " RACKETBC_SUFFIX="
                      "")))
  (define GC-topic (if (equal? variant "cs")
                       "GC:major"
                       "GC"))

  (define env-vars
    (string-append
     "env"
     " PLTSTDERR=\"debug@" GC-topic " error\""
     " PLT_SETUP_SHOW_TIMESTAMPS=enabled"
     (if no-gc? " PLT_SETUP_NO_FORCE_GC=enabled" "")))
  (define make-build-args
    (string-append (if machine-independent? " SETUP_MACHINE_FLAGS=-M" "")))

  (cond
    [distro?
     (define rkt-dir (build-path work-dir "racket"))
     (define build-dir (build-path rkt-dir "src" "build"))
     (make-directory* build-dir)
     (parameterize ([current-directory build-dir])
       (system! (string-append "../configure --enable-origtree"
                               (if (equal? variant "cs")
                                   " --enable-csdefault"
                                   "")
                               (if (equal? variant "bc")
                                   " --enable-bcdefault"
                                   "")
                               (if racket
                                   (format " --enable-racket=~a" racket)
                                   "")))
       (system! (format "make -j ~a" (processor-count)))
       (system! (string-append
                 env-vars
                 " make install"
                 make-build-args
                 (string-append " PLT_SETUP_OPTIONS='-j 1"
                                (if log-verbose? " -v" "")
                                "'")
                 " > ../../../build-log.txt 2>&1")))]
    [else
     (define plt-dir (build-path work-dir "plt"))
     (parameterize ([current-directory work-dir])
       (unless (directory-exists? plt-dir)
         (system! "git clone https://github.com/racket/racket plt"))

       (parameterize ([current-directory plt-dir])
         (unless skip-clean?
           (system! "git clean -d -x -f"))
         (system! "git pull")

         (system! (format "make -j ~a ~a ~a" (processor-count) (variant-of "base") config))

         (system! (format "racket/bin/raco pkg config --set download-cache-max-files 10240"))
         (system! (format "racket/bin/raco pkg config --set download-cache-max-bytes 671088640"))

         (system! (string-append
                   env-vars
                   " make " (variant-of "in-place")
                   " CPUS=1 " config make-build-args
                   (if log-verbose? " PLT_SETUP_OPTIONS=-v" "")
                   (if for-pkgs (format " PKGS=\"~a\"" for-pkgs) "")
                   (if src-catalog (format " SRC_CATALOG=~s" src-catalog) "")
                   " > ../build-log.txt 2>&1"))))])

  (read-and-plot (list "build-log.txt") #f #f #t)

  (when bucket
    (upload bucket #:available-plots available-plots))
  (flush-output)

  (when beat-bucket
    (beat beat-bucket beat-task-name)))
