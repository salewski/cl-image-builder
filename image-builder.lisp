;;;;
;;;; This package helps you to create custom standalone Common Lisp images
;;;; and to compile your project into a standalone app.
;;;;
;;;; Basically you have to define the *image-builder-config* and run (from
;;;; shell)
;;;;
;;;; - with SBCL:
;;;;     sbcl --no-sysinit --no-userinit --load image-builder.lisp --eval '(image-builder:build-image)'
;;;; - with CCL
;;;;    ccl64  -n -l image-builder.lisp --eval '(image-builder:build-image)'
;;;;

(require :asdf)

;; (asdf:disable-output-translations)
;; asdf:system-relative-pathname

(defpackage #:image-builder
  (:use #:cl)
  (:export
   #:build-image
   #:upgrade
   #:upgrade-or-build))

(in-package #:image-builder)


(defparameter *quicklisp-bootstrap-file* #P"quicklisp.lisp"
  "Path to the quicklisp bootstrap file relative to BUILD-DIR from the
CONFIGURATION.")

(defparameter *quicklisp-directory* #P"quicklisp/"
  "Quicklisp intallation directory relative to BUILD-DIR from the
CONFIGURATION.")

(defparameter *quicklisp-local-projects-directory* 
  (merge-pathnames #P"local-projects/" *quicklisp-directory*)
  "Quicklisp local projects directory relative to *QUICKLISP-DIRECTORY*.")

(defparameter *quicklisp-init-file*
  (merge-pathnames #P"setup.lisp" *quicklisp-directory*)
  "Path to the quicklisp setup file relative to *QUICKLISP-DIRECTORY*.")


(defparameter *default-build-dir*
  #P"build/"
  "Default root of build directory overridden by :BUILD-DIR in
the configuration.")

(defparameter *default-quicklisp-setup-url*
  "http://beta.quicklisp.org/quicklisp.lisp"
  "URL from where to download QuickLisp.")





(defstruct configuration
  "CONFIGURATION structure where (asterisk items are mandatory):

- :PACKAGES is a list of packages composing your project.

- :ENTRY-POINT is the function to call when the lisp image is loaded. Let
  this option blank if you want to create a custom lisp image.

- :OPTIONS list of option to be passed to SB-EXT:SAVE-LISP-AND-DIE or
  CCL:SAVE-APPLICATION.

- :CUSTOM-SYSTEMS list of CUSTOM-SYSTEMS to be downloaded in the Quiclisp
  local-projects folder.

- :BUILD-DIR directory where to install Quicklisp and all
  dependencies. Overrides *DEFAULT-BUILD-DIR*

- :QUICKLISP-URL override *DEFAULT-QUICKLISP-SETUP-URL*
"
  (packages)
  (entry-point)
  (output-file)
  (options
   #+sbcl '(:compression t))
  (custom-systems)
  (build-dir *default-build-dir*)
  (quicklisp-url *default-quicklisp-setup-url*))

(defstruct custom-system
  "Definition of a custom system where:

- :URL an URL from where to download the custom system.

- :METHOD which method to use to downlowd the custom system. Supported
  values are :GIT.
"
  url
  method
  branch)


(defmacro with-handler-case ((&key
				(exit-code 1)
				debug
				(error-string "~%Fatal: ~a~%"))
			     &body body)
  "Execute BODY in a safe way around a HANDLER-CASE macro.

If an exception is triggered, display ERROR-STRING and exit program
 with EXIT-CODE.

If DEBUG is defined, call INVOKE-DEBUGGER."
  `(handler-case ,@body
     (condition (c)
       (format *error-output* ,error-string c)
       (if ,debug
	   (invoke-debugger c)
	   (uiop:quit ,exit-code)))))



(defun load-configuration(file)
  "Load IMAGE-BUILDER configuration from FILE and return a CONFIGURATION
structure."
  (with-open-file (stream file :external-format :utf-8)
    (let ((data (make-string (file-length stream))))
      (read-sequence data stream)
      (with-handler-case
	  (:exit-code 3
	   :error-string
	   (format nil
		   "~%Cannot load configuration file ~a:~% ~~a~%~%"
		   file))
	  (apply #'make-configuration (read-from-string data))))))



(defun quicklisp-installedp (build-dir
			     &key (setup-file *quicklisp-init-file*))
 "Test if quicklisp is installed in BUILD-DIR by probing the existence of
SETUP-FILE."
  (probe-file (merge-pathnames setup-file
			       ;; (pathname-as-directory
				build-dir)))

(defun install-or-load-quicklisp
    (&key
       (url *default-quicklisp-setup-url*)
       (build-dir *default-build-dir*)
       (setup-file *quicklisp-init-file*)
       (quicklisp-bootstrap *quicklisp-bootstrap-file*))
    "Install Quicklisp into BUILD-DIR of load SETUP-FILE if Quicklisp is
already installed into BUILD-DIR.

If Quicklisp is not installed yet, the QUICKLISP-BOOTSTRAP file is
downloaded from URL and loaded using curl."
  (let* ((ql-init (merge-pathnames setup-file build-dir))
	 (ql-dir (pathname (directory-namestring ql-init)))
	 (ql-bootstrap (merge-pathnames quicklisp-bootstrap build-dir)))

    ;; Download quicklisp bootstrap
    (if (quicklisp-installedp build-dir :setup-file setup-file)
	(progn
	  (format t "Loading Quicklisp from ~a~%" ql-init)
	  (load ql-init)
	  ;; Ned to explicitly load UIOP on some Lisps (SBCL)
	  (funcall (intern "QUICKLOAD" "QUICKLISP") :uiop))
	(progn
	  (format t "Installing Quicklisp to ~a~%" ql-dir)
	  (ensure-directories-exist ql-dir)
	  (asdf:run-shell-command
	   (format nil "curl -o ~a ~a" ql-bootstrap url))
	  (load ql-bootstrap)
	  ;; Delete quicklisp from memory before installing it.
	  (when (find-package '#:ql)
	    (delete-package '#:ql))
	  ;; Bootstrap Quicklisp
	  (funcall (intern "INSTALL" "QUICKLISP-QUICKSTART")
		   :path ql-dir)
	  (funcall (intern "QUICKLOAD" "QUICKLISP") :uiop)))))

(defun install-system-git (system target)
  "Install SYSTEM into TARGET directory using git command."
  (let* ((url (custom-system-url system))
	 (directory (when url (pathname-name url)))
	 (target (when directory
		   (merge-pathnames directory target)))
	 (branch (custom-system-branch system)))
    (when target
      (unless (probe-file target)
	(asdf:run-shell-command
	 (format nil "git clone ~@[-b '~a'~] ~a ~a" branch url target))))))

(defun install-custom-systems
    (custom-systems
     &key (build-dir *default-build-dir*)
       (local-project *quicklisp-local-projects-directory*))
  "Download every custom system defined in CUSTOM-SYSTEMS list in the
LOCAL-PROJECT directory of BUILD-DIR.

CUSTOM-SYSTEMS is a list of CUSTOM-SYSTEM structure.
"
  (let ((lp-dir (merge-pathnames local-project build-dir)))
    (loop for system in custom-systems
	  for syst = (apply #'make-custom-system system)
	  do (progn
	       (cond
		 ((eq :git (custom-system-method syst))
		  (install-system-git syst lp-dir)))))))


(defun load-packages (packages)
  "Load quicklisp PROJECTS."
  (when packages
    (let ((asdf:*central-registry* (list *default-pathname-defaults*)))
      (funcall (intern "QUICKLOAD" "QUICKLISP") packages))))


(defun split-string-by-char (string &key (char #\:))
    "Returns a list of substrings of string
divided by ONE space each.
Note: Two consecutive spaces will be seen as
if there were an empty string between them."
  (remove-if #'(lambda(x) (string= "" x))
	     (loop for i = 0 then (1+ j)
		   as j = (position char string :start i)
		   collect (subseq string i j)
		   while j)))

(defun string-to-function-symbol(string)
  "Convert STRING to its symbol function representation."
  (let ((elements (split-string-by-char (string-upcase string) :char #\:)))
    (when elements
      (apply #'intern (reverse elements)))))


(defun write-image (&key entry-point file-output options)
  "Write the common lisp image of current running lisp instance.

If an ENTRY-POINT is defined, that function would be called when the
instance is loaded again. The ENTRY-POINT function is call with all command
line argument as a list parameter, thus you don't have to worry about how to
retrieve command line arguments. The ENTRY-POINT signature should be
something like:

  (defun main (argv) ... )

FILE-OUTPUT is the basename of the file to be written. The output file is
suffixed with the lisp implementation you use and \".exe\". I t would result
of \"FILE-OUTPUT.sbcl.exe\" or \"FILE-OUTPUT.ccl.exe\"

A list of OPTIONS can be passed to UIOP/IMAGE:DUMP-IMAGE."
  (let* ((entry-function (string-to-function-symbol entry-point))
	 (args (append
		(cons (format nil "~a.~a.exe"
			      file-output
			      #+sbcl "sbcl"
			      #+ccl "ccl"
			      #-(or sbcl ccl) "CL")
		      options)
		(when entry-point (list :executable t)))))
    
    (when entry-function
      ;; We want a pristine hook
      (setq uiop:*image-restore-hook*
	    '(uiop/stream::setup-stdin
	      uiop/configuration::compute-user-cache
	      uiop/image:setup-command-line-arguments uiop/stream:setup-stderr
	      uiop/stream:setup-temporary-directory))
      (uiop/image:register-image-restore-hook
       #'(lambda() (funcall entry-function (uiop:raw-command-line-arguments)))
       nil))
    (apply #'uiop/image:dump-image args)))

(defun build-image (&key
		      (config-file #P".image-builder.lisp")
		      (install-quicklisp t)
		      (custom-systems t)
		      (load-packages t)
		      )
  "Build a custom lisp image from configuration read from  CONFIG-FILE.

If INSTALL-QUICKLISP is NIL Quicklisp setup would be skipped. IF
CUSTOM-SYSTEMS is NIL none of custom system definition would be loaded. If
LOAD-PACKAGES is NIL, no package defined in the CONFIG-FILE
would be loaded.

If the build succeed the program exits to the shell."
  (let ((conf (load-configuration config-file)))
    ;;
    (when install-quicklisp
      (install-or-load-quicklisp
       :url (configuration-quicklisp-url conf)
       :build-dir (configuration-build-dir conf)))

    (when custom-systems
      (install-custom-systems (configuration-custom-systems conf)))

    (when load-packages
      (load-packages (configuration-packages conf)))

    (write-image
     :entry-point (configuration-entry-point conf)
     :file-output (configuration-output-file conf)
     :options (configuration-options conf))))

(defun get-system-lisp-files (system)
  "Return a list of all lisp files from SYSTEM searched from the current
directory.

The returned list is in the order asdf would load the files."
  (let* ((asdf:*central-registry* (list *default-pathname-defaults*))
	 (asdf-files (asdf:input-files 'asdf:load-op system))
	 (sysdefs (loop :for asdf in asdf-files
			:collect
			(let ((system (asdf::remove-plist-key
				       :depends-on
				       (asdf::safe-read-file-form asdf))))
			  (when (not (getf system :pathname))
			    (setq system (append system (list :pathname ""))))
			  (setf (getf system :pathname)
				(merge-pathnames (getf system :pathname)
						 ;; on some systems
						 ;; *default-pathname-defaults*
						 ;; is not absolute.
						 (truename
						  *default-pathname-defaults*)))
			  (eval system)))))
    (loop for sysdef in sysdefs
	  :nconc 
	  (loop :for (o . c) in (asdf/plan:plan-actions
				 (asdf:make-plan
				  asdf/plan:*default-plan-class* 'asdf:load-op sysdef))
		:when (and
		       (eq 'asdf/lisp-action:load-op (type-of o))
		       (eq 'asdf/lisp-action:cl-source-file (type-of c)))
		  :collect (asdf::component-pathname c)))))

(defun upgrade-asdf (system &key verbose)
  (let ((files (get-system-lisp-files system)))
    (loop :for file in files
	  :do (progn
		(when verbose
		  (format t "Loading ~a~%" file))
		(load file)))))

(defun upgrade (&key (config-file #P".image-builder.lisp") verbose)
  "Upgrade current image using CONFIG-FILE settings. If VERBOSE is T,
display file name being loaded."
  (let* ((conf (load-configuration config-file)))
    (when verbose
      (format t "Loading ~A~%" (configuration-packages conf)))
    (upgrade-asdf (configuration-packages conf) :verbose verbose)
    
    (write-image
     :entry-point (configuration-entry-point conf)
     :file-output (configuration-output-file conf)
     :options (configuration-options conf))))


(defun upgrade-or-build (&key
			   (config-file #P".image-builder.lisp")
			   (install-quicklisp t)
			   (custom-systems t)
			   (load-packages t)
			   verbose
			   upgrade)
  "Either call UPGRADE or BUILD-IMAGE depending if UPGRADE is T or NIL."
  (if upgrade
      (upgrade :config-file config-file :verbose verbose)
      (build-image :config-file config-file
		   :install-quicklisp install-quicklisp
		   :custom-systems custom-systems
		   :load-packages load-packages)))
