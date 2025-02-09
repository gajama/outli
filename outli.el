;;; outli.el --- Org-like code outliner  -*- lexical-binding: t -*-

;; Copyright (C) 2022  

;; Author: J.D. Smith <jdtsmith@gmail.com>
;; URL: https://github.com/jdtsmith/outli
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.0.2
;; Keywords: convenience, outlines, Org

;;; License:

;; outli is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; outli is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; outli-mode is a simple minor-mode on top of outline-minor-mode
;; which supports configurable special comment lines as level-aware
;; outline headings which can be collapsed, navigated, moved, etc.
;; outli styles headings for easy level recognition and provides a
;; org-mode-like header navigation and editing capabilities, including
;; speed keys activated at the start of headings.
;; 
;; Customize `outli-heading-config' to set the "stem" and "repeat"
;; character for comment-based headings and to influence how the
;; headings are styled.  Customize `outli-speed-commands' to alter or
;; disable speed keys, which work at the beginning of heading lines
;; only.

;;; Code:

(require 'outline)
(require 'color)
(require 'org-keys)
(require 'org-faces)

;;;; Variables 
(defgroup outli nil
  "Simple comment outlining."
  :tag "Outli"
  :group 'outlines)

(defcustom outli-heading-config
  '((emacs-lisp-mode ";;" ?\; t)
    (tex-mode "%%" ?% t)
    (org-mode . nil)
    (t (let* ((c (or comment-start "#"))
	      (space (unless (eq (aref c (1- (length c))) ?\s) " ")))
	 (concat c space))
       ?*))
  "Formatting configuration for outli comment headings.
The configuration is an alist with each element in one of two forms:

 (MAJOR-MODE STEM REPEAT-CHAR STYLE NO-BAR)

with entries for the first form:

- key MAJOR-MODE (a mode symbol, or t)
- initial string STEM
- REPEAT-CHAR, a character the count of which denotes heading
  depth
- optional STYLE: If the symbol 'none, no styling of any kind is
  applied to headings.  If otherwise non-nil, the stem and repeat
  character parts of the heading both get identical stem-styling.
- optional boolean NO-BAR: if non-nil, omit the overline styling
  for this mode.

or

 (MAJOR-MODE . nil) 

which will disable outli in any modes derived from this mode.

STEM and REPEAT-CHAR are eval'd if expressions.  To provide a
default setting for any mode as backup, specify MAJOR-MODE as t.
Note that ordering is important, as settings from the first
matching mode are used."
  :group 'outli
  :type '(alist :key-type (choice (const :tag "Default" t) (symbol :tag "Major Mode"))
		:value-type
		(choice (const :tag "Disable" nil)
			(list :tag "Configure"
			      (choice :tag "Stem" string sexp)
			      (character :tag "Repeat Char")
			      (choice :tag "Style"
				      (const :tag "No Styling" 'none)
				      (const :tag "Uniform Style" t)
				      (const :tag "Default Style" nil))
			      (boolean :tag "Omit Overline")))))

(defcustom outli-blend 0.25
  "Blended color to decorate initial heading background.
Either nil for no blended background, or a floating point number
<=1.0, representing the fraction of the heading foreground color
to blend with the background."
  :group  'outli
  :type '(choice (const :tag "Disable" nil) float))

(defcustom outli-speed-commands
  '(("Outline Navigation")
    ("n" . outline-next-visible-heading)
    ("p" . outline-previous-visible-heading)
    ("f" . outline-forward-same-level)
    ("b" . outline-backward-same-level)
    ("u" . outline-up-heading)
    ("Outline Visibility")
    ("c" . outline-cycle)
    ("C" . outline-cycle-buffer)
    ("s" . outli-toggle-narrow-to-subtree)
    ("h" . outline-hide-sublevels)
    ("1" . (outline-hide-sublevels 1))
    ("2" . (outline-hide-sublevels 2))
    ("3" . (outline-hide-sublevels 3))
    ("4" . (outline-hide-sublevels 4))
    ("5" . (outline-hide-sublevels 5))
    ("Outline Structure Editing")
    ("U" . outline-move-subtree-up)
    ("D" . outline-move-subtree-down)
    ("r" . outline-demote)
    ("l" . outline-promote)
    ("i" . outli-insert-heading-respect-content)
    ("@" . outline-mark-subtree) 
    ("?" . outli-speed-command-help))
  "Alist of speed commands.

The car of each entry is a string with a single letter, which
must be assigned to `self-insert-command' in the global map.

The cdr is either a command to be called interactively, a
function to be called, or a form to be evaluated.

An entry that is just a list with a single string will be
interpreted as a descriptive headline that will be added when
listing the speed commands in the Help buffer using the `?' speed
command."
  :group 'outfin
  :type '(repeat :value ("k" . ignore)
		 (choice :value ("k" . ignore)
			 (list :tag "Descriptive Headline" (string :tag "Headline"))
			 (cons :tag "Letter and Command"
			       (string :tag "Command letter")
			       (choice
				(function)
				(sexp))))))

(defvar-local outli-heading-stem nil
  "The initial stem for headings.  Defaults to 2x comment-start.")

(defvar-local outli-heading-char nil
  "Character used to indicate heading depth.  Defaults to commment-start.")

;;;; Outline Headings
(defun outli-heading-regexp ()
  (if (and outli-heading-stem outli-heading-char)
      (rx-to-string `(group ,outli-heading-stem (+ ,outli-heading-char) ?\s))))

(defun outli-indent-level ()
  (or (cdr (assoc (match-string 0) outline-heading-alist))
      (- (match-end 0) (match-beginning 0) (length outli-heading-stem) 1)))

(defun outli--on-heading (cmd)
  (if (outline-on-heading-p) cmd))

(defun outli--at-heading (cmd)
  (and
   (if (bolp)
       (looking-at outline-regexp)
     (and (save-excursion
	    (forward-line 0)
	    (looking-at outline-regexp))
	  (>= (match-end 0) (point))))
   cmd))

;;;; Outline Commands
(defun outli-toggle-narrow-to-subtree ()
  "Narrow to sub-tree or widen if already narrowed."
  (interactive)
  (if (buffer-narrowed-p)
      (widen)
    (let ((beg))
      (if (outline-on-heading-p)
	  (beginning-of-line)
	(outline-previous-visible-heading 1))
      (setq beg (point))
      (save-excursion
	(outline-end-of-subtree)
	(narrow-to-region beg (point))))))

(defun outli-insert-heading-respect-content ()
  "Add a new heading at the current level after any contents."
  (interactive)
  (let ((head (save-excursion
		(condition-case nil
		    (outline-back-to-heading)
		  (error (outline-next-heading)))
		(if (eobp)
		    (or (caar outline-heading-alist) "")
		  (match-string 0)))))
    (unless (or (string-match "[ \t]\\'" head)
		(not (string-match (concat "\\`\\(?:" outline-regexp "\\)")
				   (concat head " "))))
      (setq head (concat head " ")))
    (outline-end-of-subtree)
    (unless (bolp) (insert "\n"))
    (insert head)
    (unless (eolp)
      (save-excursion (newline-and-indent)))
    (run-hooks 'outline-insert-heading-hook)))

;;;; Fontification 
(defun outli-fontify-background-blend (fg)
  "Compute blended background color for headline match based on foreground FG.
Returns blended background color."
  (let* ((frac (- 1.0 outli-blend))
	 (bg (frame-parameter nil 'background-color))
	 (cols (mapcar #'color-name-to-rgb `(,bg ,fg))))
    (if (cl-every (lambda (c) (and (consp c) (cl-every #'numberp c))) cols)
	(apply #'color-rgb-to-hex
	       (apply #'cl-mapcar (lambda (a b)
				    (+ (* a frac)
				       (* b (- 1.0 frac))))
		      cols)))))
(defvar-local outli-font-lock-keywords nil)

(defun outli-fontify-headlines (&optional style nobar)
  "Calculate and enable font-lock regexps to match headings.
If STYLE is non-nil, do not style the stem and depth chars
differently.  If it is the symbol 'none, omit all styling.  If
NOBAR is non-nil, omit the overlines."
  (unless (eq style 'none)
    (font-lock-add-keywords
     nil
     (setq outli-font-lock-keywords
	   (cl-loop for i downfrom 8 to 1
		    for ol-face = (intern-soft (format "org-level-%d" i))
		    for fg = (face-attribute ol-face :foreground nil t)
		    with ot = (unless nobar '(:overline t))
		    for header-highlight = `(4 '(:inherit ,ol-face :extend t ,@ot) t)
		    for extra-highlight =
		  
		    (let ((ofg (unless nobar `(:overline ,fg))))
		      (if outli-blend
			  (let ((blend (outli-fontify-background-blend fg)))
			    (if style
				`((1 '(:background ,blend ,@ofg) append))
			      `((3 '(:inherit ,ol-face :background ,blend ,@ot) t)
				(2 '(:background ,blend ,@ofg) append))))
			`((1 '(,@ofg) append))))
		    for hrx = (rx-to-string
			       `(and
				 bol
				 (group (group (literal ,outli-heading-stem))
					(group (= ,i ,outli-heading-char)))
				 (group ?\s (* nonl) (or ?\n eol)))
			       t)
		    collect `(,hrx ,header-highlight ,@extra-highlight))))
    (mapc (lambda (x) (cl-pushnew x font-lock-extra-managed-props))
	  `(extend overline ,@(if outli-blend '(background))))
    (font-lock-flush)))

(defun outli-unfontify ()
  "Remove existing fontification."
  (font-lock-remove-keywords nil outli-font-lock-keywords)
  (setq outli-font-lock-keywords nil)
  (font-lock-flush))

;;;; Key Bindings
(defun outli-speed-command-help ()
  "Show the available speed commands."
  (interactive)
  (with-output-to-temp-buffer "*Help*"
    (princ "Speed commands\n==============\n")
    (mapc #'org-print-speed-command outli-speed-commands))
  (with-current-buffer "*Help*"
    (setq truncate-lines t)))

(defvar outli-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Tab: cycle, if on heading
    (define-key map (kbd "<tab>")
      `(menu-item "" outline-cycle :filter outli--on-heading))
    ;; Shift-Tab: cycle buffer
    (define-key map (kbd "S-<tab>") #'outline-cycle-buffer)
    map))

;;;; Outli mode 
;;;###autoload
(define-minor-mode outli-mode
  "Simple outline mode interaction based on comment-headings."
  :keymap outli-mode-map
  (if outli-mode
      (let  ((config (seq-find
		      (lambda (e) (derived-mode-p (car e)))
		      outli-heading-config)))
	(if (and config (eq (cdr config) nil))
	    (setq outli-mode nil) 	; Mode explicitly disabled
	  ;; Speed keys
	  (cl-loop for (key . com) in outli-speed-commands do
		   (when-let ((func
			       (cond
				((functionp com) com)
				((consp com) (eval `(lambda () (interactive) ,com))))))
		     (define-key outli-mode-map (kbd key)
		       `(menu-item "" ,func :filter outli--at-heading))))

	  ;; Setup the heading matchers
	  (pcase-let ((`(_ ,stem ,rchar ,style ,nobar)
		       (or config
			   (assq t outli-heading-config)
			   '(t nil nil nil))))
	    (setq outli-heading-char
		  (or (if (consp rchar) (eval rchar) (if (characterp rchar) rchar)) ?*)
		  outli-heading-stem
		  (or (and (consp stem) (eval stem)) (and (stringp stem) stem) "# ")
		  outline-regexp (outli-heading-regexp)
		  outline-heading-end-regexp "\n"
		  outline-level #'outli-indent-level)
	    ;; pre-seed the level alist for efficiency
	    (cl-loop for level downfrom 8 to 1 do
		     (push (cons (concat outli-heading-stem
					 (make-string level outli-heading-char) " ")
				 level)
			   outline-heading-alist))
	    (cl-pushnew `("Headings" ,(rx bol (regexp outline-regexp) (group-n 2 (* nonl) eol)) 2)
			imenu-generic-expression)
	    (outli-fontify-headlines style nobar))
	  (outline-minor-mode 1)))
    (outline-minor-mode -1)
    (outli-unfontify)))

;;;; Footer
(provide 'outli)

;;; outli.el ends here
