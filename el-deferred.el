;;; el-deferred.el --- Simple asynchronous functions for emacs lisp

;; Copyright (C) 2010  SAKURAI Masashi

;; Author: SAKURAI Masashi <m.sakurai@kiwanami.net>
;; Keywords: lisp, async

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; el-deferred is a simple library for asyncronous tasks.  The API is
;; almost the same as JSDeferred written by cho45. (See the web site
;; http://coderepos.org/share/wiki/JSDeferred)

;;; API

;; deferred:new
;; deferred:start

;; deferred:call
;; deferred:apply

;; deferred:next
;; deferred:nextc

;; deferred:wait
;; deferred:waitc

;; deferred:loop
;; deferred:loopc

;; deferred:error
;; deferred:cancel

;; deferred:parallel
;; deferred:parallelc
;; deferred:earlier
;; deferred:earlierc
;; deferred:chain
;; deferred:chainc

;;; Notes

;; The difference from JSDeferred 

;;

;; 

(eval-when-compile
  (require 'cl))

;;; Code:

(defmacro deferred:aand (test &rest rest)
  `(let ((it ,test))
     (if it ,(if rest (macroexpand-all `(deferred:aand ,@rest)) 'it))))

(defun deferred:setTimeout (msec f)
  "[internal] Timer function that emulates the `setTimeout' function in JS."
  (run-at-time (/ msec 1000.0) nil f) nil)

;; debug

(eval-and-compile
  (defvar deferred:debug nil "Debug output switch."))
(defvar deferred:debug-count 0 "[internal] Debug output counter.")

(defmacro deferred:message (&rest args)
  "[internal] Debug log function."
  (when deferred:debug
    `(progn 
       (with-current-buffer (get-buffer-create "*deferred:debug*")
         (save-excursion
           (goto-char (point-max))
           (insert (format "%5i %s\n" deferred:debug-count (format ,@args)))))
       (incf deferred:debug-count))))

(defun deferred:message-mark ()
  "[internal] Debug log function."
  (interactive)
  (deferred:message "==================== mark ==== %s" 
    (format-time-string "%H:%M:%S" (current-time))))

(defun deferred:save-debug (&optional filename)
  "[internal] Save debug log."
  (interactive)
  (unless filename
    (setq filename "el-deferred-debug.txt"))
  (with-current-buffer (get-buffer-create "*deferred:debug*")
    (write-file filename nil)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Backend functions of deferred tasks

(defvar deferred:queue nil
  "[internal] The execution queue of deferred objects. 
See the functions `deferred:post-queue' and `deferred:worker'.")

(defmacro deferred:pack (a b c)
  `(cons ,a (cons ,b ,c)))

(defun deferred:post-queue (d which &optional arg)
  "[internal] Add a deferred object to the execution queue
`deferred:queue' and schedule to execute.
D is a deferred object. WHICH is a symbol, `ok' or `ng'. ARG is
an argument value for execution of the deferred task."
  (push (deferred:pack d which arg) deferred:queue)
  (deferred:message "QUEUE-POST [%s]: %s" 
    (length deferred:queue) (deferred:pack d which arg))
  (deferred:schedule-worker)
  d)

(defun deferred:schedule-worker ()
  "[internal] Schedule consuming a deferred task in the execution queue."
  (run-at-time 0.001 nil 'deferred:worker))

(defun deferred:clear-queue ()
  "Clear the execution queue. For test and debugging."
  (deferred:message "QUEUE-CLEAR [%s -> 0]" (length deferred:queue))
  (setq deferred:queue nil))

(defun deferred:esc-msg (msg)
  "[internal] Escaping the charactor '%'."
  (replace-regexp-in-string
   "\\([^%]\\)%\\([^%]\\)" "\\1%%\\2" msg))

(defun deferred:worker ()
  "[internal] Consume a deferred task. 
Mainly this function is called by timer asynchronously."
  (when deferred:queue
    (let* ((pack (car (last deferred:queue)))
           (d (car pack))
           (which (cadr pack))
           (arg (cddr pack)) value)
      (condition-case err
          (setq value (deferred:post-message d which arg))
        (error 
         (deferred:message "ERROR : %s" err)
         (message "el-deferred error : %s" err)))
      (setq deferred:queue (nbutlast deferred:queue))
      value)))

(defun deferred:remove-from-queue (d)
  "[internal] Remove the deferred object from the execution queue
so that the deferred task will not be called twice."
  (setq deferred:queue 
        (loop for pack in deferred:queue
              unless (eq d (car pack))
              collect pack)))

(defun deferred:fire-queue! ()
  "Call all deferred tasks synchronously. For test and debugging."
  (let (value)
    (while deferred:queue
      (setq value (deferred:worker)))
    value))



(defun deferred:default-callback (i)
  "[internal] Default callback function."
  (identity i))

(defun deferred:default-errorback (error-msg)
  "[internal] Default errorback function."
  (error error-msg))

(defun deferred:default-canceller (d)
  "[internal] Default cancelling function."
  (deferred:message "CANCEL : %s" d)
  (setf (deferred-callback-ok d) 'deferred:default-callback)
  (setf (deferred-callback-ng d) 'deferred:default-errorback)
  (setf (deferred-next d) nil)
  d)

;; Struct: deferred
;; 
;; callback-ok : ok function (default `deferred:default-callback')
;; callback-ng : ng function (default `deferred:default-errorback')
;; canceller   : cancelling function (default `deferred:default-canceller')
;; next        : next chained deferred object (default nil)
;; 
(defstruct deferred
  (callback-ok 'deferred:default-callback)
  (callback-ng 'deferred:default-errorback)
  (canceller 'deferred:default-canceller)
  next)

(defun deferred:set-next (prev next)
  "[internal] Connect deferred objects."
  (setf (deferred-next prev) next))

(defun deferred:post-message (d which &optional arg)
  "[internal] Executing deferred task. If the deferred object has
next deferred task or the return value is a deferred object, this
function adds the task to the execution queue.
D is a deferred object. WHICH is a symbol, `ok' or `ng'. ARG is
an argument value for execution of the deferred task."
  (deferred:message "EXEC : %s / %s / %s" d which arg)
  (when (null d) (error "deferred:post-message was given a nil."))
  (let ((callback (if (eq which 'ok) 
                      (deferred-callback-ok d)
                    (deferred-callback-ng d))))
    (cond
     (callback
      (let (value (next-deferred (deferred-next d)))
        (condition-case err
            (progn 
              (setq value
                    (apply callback (list arg)))
              (cond
               ((deferred-p value)
                (deferred:message "EXEC NEST : %s" value)
                (deferred:set-next value next-deferred)
                (deferred:post-queue value 'ok nil))
               (t
                (if next-deferred
                    (deferred:post-queue next-deferred 'ok value)
                  value))))
          (error 
           (cond
            (next-deferred
             (deferred:post-queue next-deferred 'ng (error-message-string err)))
            (deferred:onerror
              (funcall deferred:onerror err))
            (t
             (error (deferred:esc-msg (error-message-string err)))))))))
     ((null callback)
      (let ((next-deferred (deferred-next d)))
        (cond
         (next-deferred
          (deferred:post-message next-deferred which arg))
         ((eq which 'ok) arg)
         (t (error (deferred:esc-msg arg)))))))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Basic deferred functions

(defvar deferred:onerror nil 
  "Default error handler. This value is nil or a function that
  have one argument for the error message.")

(defun deferred:call (f &rest args)
  "Call the given function asynchronously."
  (lexical-let ((f f) (args args))
    (deferred:next
      (lambda (x)
        (apply f args)))))

(defun deferred:apply (f &optional args)
  "Call the given function asynchronously."
  (lexical-let ((f f) (args args))
    (deferred:next
      (lambda (x)
        (apply f args)))))

(defun deferred:new (&optional callback)
  "Create a deferred object."
  (if callback
      (make-deferred :callback-ok callback)
    (make-deferred)))

(defun deferred:start (d &optional arg)
  "Add the deferred object to the execution queue."
  (deferred:post-queue d 'ok arg))

(defun deferred:next (callback &optional arg)
  "Create a deferred object and schedule executing. This function
is a short cut of following code:
 (deferred:start (deferred:new aform))."
  (let ((d (make-deferred :callback-ok callback)))
    (deferred:start d arg)
    d))

(defun deferred:nextc (d callback)
  "Create a deferred object with OK callback and connect it to the given deferred object."
  (let ((nd (make-deferred :callback-ok callback)))
    (deferred:set-next d nd)
    nd))

(defun deferred:error (d callback)
  "Create a deferred object with errorback and connect it to the given deferred object."
  (let ((nd (make-deferred :callback-ng callback)))
    (deferred:set-next d nd)
    nd))

(defun deferred:cancel (d)
  "Cancel all callbacks and deferred chain in the deferred object."
  (deferred:message "CANCEL : %s" d)
  (funcall (deferred-canceller d) d)
  d)

(defun deferred:wait (msec)
  "Return a deferred object scheduled at MSEC millisecond later."
  (lexical-let 
      ((d (deferred:new)) (start-time (float-time)))
    (deferred:message "WAIT : %s" msec)
    (deferred:setTimeout msec 
      (lambda () 
        (deferred:post-message d 'ok 
          (* 1000.0 (- (float-time) start-time)))
        nil))
    d))

(defun deferred:waitc (d msec)
  "Create a wait task and connect it to the given deferred object."
  (lexical-let ((msec msec)
                (nd (deferred:new)))
    (deferred:nextc d 
      (lambda (x) 
        (lexical-let ((start-time (float-time)))
          (deferred:message "WAITC : %s" msec)
          (deferred:setTimeout 
            msec
            (lambda ()
              (deferred:post-message nd 'ok 
                (* 1000.0 (- (float-time) start-time)))
              nil)))
        nil))
    nd))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility functions

(defun deferred:loop (times func)
  "Return a iteration deferred object."
  (deferred:message "LOOP : %s" times)
  (deferred:aand
    (deferred:next 'identity)
    (if (<= times 0) it
      (deferred:loop-iter 
        (deferred:next 'identity)
        times func))))

(defun deferred:loopc (d times func)
  "Connect a iteration deferred object to the given deferred object."
  (deferred:message "LOOPC : %s" times)
  (if (< 0 times)
      (deferred:loop-iter d times func)
    d))

(defun deferred:loop-iter (prev-deferred times func)
  "[internal] Iteration main."
  (loop for i from 0 below times
        with ld = prev-deferred
        do (setq ld 
                 (lexical-let ((i i) (func func))
                   (deferred:nextc ld (lambda (x) (funcall func i)))))
        finally return ld))

(defun deferred:parallel (&rest args)
  "Return a deferred object that calls given deferred objects or
functions parallelly and wait for all callbacks. The following
deferred task will be called with an array of the return
values. ARGS can be a list or an alist of deferred objects or
functions."
  (deferred:message "PARALLEL : %s" args)
  (apply 'deferred:parallelc (deferred:next 'identity) args))

(defun deferred:parallelc (d &rest args)
  "Connect the parallel deferred object and connect it to the
given deferred object.  The parallel deferred object calls given
deferred objects or functions parallelly and waits for all
callbacks. The following deferred task will be called with an
array of the return values. ARGS can be a list or an alist of
deferred objects or functions."
  (deferred:message "PARALLELC : %s" args)
  (cond
   ((and (= 1 (length args)) (consp (car args)) (not (functionp (car args))))
    (let ((lst (car args)))
      (cond
       ((or (null lst) (null (car lst)))
        d)
       ((deferred:aand lst (car it) (or (functionp it) (deferred-p it)))
        ;; a list of deferred objects
        (deferred:parallel-list d lst))
       ((deferred:aand lst (consp it))
        ;; an alist of deferred objects
        (deferred:parallel-alist d lst))
       (t (error "Wrong argument type. %s" args)))))
   (t (deferred:parallelc d args))))

(defun deferred:parallel-list (prev-deferred lst)
  "[internal]"
  (deferred:message "PARALLEL<LIST>" )
  (setq lst (deferred:parallel-go prev-deferred lst))
  (lexical-let ((nd (deferred:new)) 
                (len (length lst))
                values fail-flag)
    (loop for d in lst
          do 
          (deferred:aand
            (deferred:nextc d
              (lambda (x)
                (push x values)
                (deferred:message "PARALLEL VALUE [%s/%s] %s" 
                  (length values) len x)
                (when (= len (length values))
                  (deferred:message "PARALLEL COLLECTED")
                  (deferred:post-queue nd 'ok values))
                nil))
            (deferred:error it
              (lambda (e)
                (push e values)
                (deferred:message "PARALLEL ERROR [%s/%s] %s" (length values) len e)
                (when (= (length values) len)
                  (deferred:message "PARALLEL COLLECTED")
                  (deferred:post-queue nd 'ok values))
                nil))))
    nd))

(defun deferred:parallel-go (prev-deferred lst)
  "[internal] TODO:"
  (setq lst
        (loop for d in lst 
              collect
              (progn
                (unless (deferred-p d)
                  (setq d (deferred:new d)))
                (deferred:remove-from-queue d)
                d)))
  (lexical-let ((lst lst))
    (deferred:nextc prev-deferred
      (lambda (x)
        (loop for d in lst
              do (deferred:post-queue d 'ok x))
        nil)))
  lst)

(defun deferred:parallel-alist (prev-deferred alst)
  "[internal]"
  (deferred:message "PARALLEL<KEY . VALUE>" )
  (setq alst (deferred:parallel-go-alist prev-deferred alst))
  (lexical-let ((nd (deferred:new)) 
                (len (length alst)) 
                values)
    (loop for pair in alst
          do 
          (lexical-let
              ((name (car pair))
               (d (cdr pair)))
            (deferred:aand
              (deferred:nextc d 
                (lambda (x)
                  (push (cons name x) values)
                  (deferred:message "PARALLEL VALUE [%s/%s] %s" 
                    (length values) len (cons name x))
                  (when (= len (length values))
                    (deferred:message "PARALLEL COLLECTED")
                    (deferred:post-queue nd 'ok values))
                  nil))
            (deferred:error it
              (lambda (e)
                (push (cons name e) values)
                (deferred:message "PARALLEL ERROR [%s/%s] %s" 
                  (length values) len (cons name e))
                (when (= (length values) len)
                  (deferred:message "PARALLEL COLLECTED")
                  (deferred:post-queue nd 'ok values))
                nil)))))
    nd))

(defun deferred:parallel-go-alist (prev-deferred alst)
  "[internal]"
  (setq alst
        (loop for pair in alst 
              collect
              (progn 
                (unless (deferred-p (cdr pair))
                  (setf (cdr pair) (deferred:new (cdr pair))))
                (deferred:remove-from-queue (cdr pair))
                pair)))
  (lexical-let ((alst alst))
    (deferred:nextc prev-deferred
      (lambda (x)
        (loop for pair in alst
              do (deferred:post-queue (cdr pair) 'ok x))
        nil)))
  alst)

(defun deferred:earlier (&rest args)
  "Return a deferred object that calls given deferred objects or
functions parallelly and wait for the first callback. The
following deferred task will be called with the first return
value. ARGS can be a list or an alist of deferred objects or
functions."
  (deferred:message "EARLIER : %s" args)
  (apply 'deferred:earlierc (deferred:next 'identity) args))

(defun deferred:earlierc (d &rest args)
  "Connect the parallel deferred object and connect it to the
given deferred object.  The parallel deferred object calls given
deferred objects or functions parallelly and wait for the first
callback. The following deferred task will be called with the
first return value. ARGS can be a list or an alist of deferred
objects or functions."
  (deferred:message "EARLIERC : %s" args)
  (cond
   ((and (= 1 (length args)) (consp (car args)) (not (functionp (car args))))
    (let ((lst (car args)))
      (cond
       ((or (null lst) (null (car lst)))
        d)
       ((deferred:aand lst (car it) (or (functionp it) (deferred-p it)))
        ;; a list of deferred objects
        (deferred:earlier-list d lst))
       ((deferred:aand lst (consp it))
        ;; an alist of deferred objects
        (deferred:earlier-alist d lst))
       (t (error "Wrong argument type. %s" args)))))
   (t (deferred:earlierc d args))))

(defun deferred:earlier-list (prev-deferred lst)
  "[internal]"
  (deferred:message "EARLIER<LIST>" )
  (setq lst (deferred:parallel-go prev-deferred lst))
  (lexical-let ((nd (deferred:new))
                (len (length lst))
                value results)
    (loop for d in lst
          do 
          (deferred:aand
            (deferred:nextc d
              (lambda (x)
                (push x results)
                (cond
                 ((null value)
                  (setq value x)
                  (deferred:message "EARLIER VALUE %s" value)
                  (deferred:post-queue nd 'ok value))
                 (t
                  (deferred:message "EARLIER MISS [%s/%s] %s" (length results) len x)
                  (when (eql (length results) len)
                    (deferred:message "EARLIER COLLECTED"))))
                nil))
            (deferred:error it
              (lambda (e)
                (push e results)
                (deferred:message "EARLIER ERROR [%s/%s] %s" (length results) len e)
                (when (and (eql (length results) len) (null value))
                  (deferred:message "EARLIER FAILED")
                  (deferred:post-queue nd 'ok nil))
                nil))))
    nd))

(defun deferred:earlier-alist (prev-deferred alst)
  "[internal]"
  (deferred:message "EARLIER<KEY . VALUE>" )
  (setq alst (deferred:parallel-go-alist prev-deferred alst))
  (lexical-let ((nd (deferred:new)) 
                (len (length lst))
                value results)
    (loop for pair in alst
          do 
          (lexical-let
              ((name (car pair))
               (d (cdr pair)))
            (deferred:aand
              (deferred:nextc d 
                (lambda (x)
                  (push (cons name x) results)
                  (cond
                   ((null value)
                    (setq value (cons name x))
                    (deferred:message "EARLIER VALUE %s" (cons name value))
                    (deferred:post-queue nd 'ok value))
                   (t
                    (deferred:message "EARLIER MISS [%s/%s] %s" (length results) len (cons name value))
                    (when (eql (length results) len)
                      (deferred:message "EARLIER COLLECTED"))))
                  nil))
              (deferred:error it
                (lambda (e)
                  (push (cons name e) results)
                  (deferred:message "EARLIER ERROR [%s/%s] %s" (length results) len (cons name e))
                  (when (and (eql (length results) len) (null value))
                    (deferred:message "EARLIER FAILED")
                    (deferred:post-queue nd 'ok nil))
                  nil)))))
          nd))


(defun deferred:chain (args)
  "Build and return a deferred chain with the given functions and
deferred objects. A list in the ARGS list is translated into a
parallel task. A set of the symbol `:error' and a following
function is translated into an errorback task."
  (deferred:chainc (deferred:next 'identity) args))

(defun deferred:chainc (d args)
  "Build and connect a deferred object to the given deferred
object. The deferred object is a chain of the given functions and
deferred objects. A list in the ARGS list is translated into a
parallel task. A set of the symbol `:error' and a following
function is translated into an errorback task."
  (let ((d d))
    (cond
     ((null args) nil)
     (t
      (loop for i in args
            with onerror-flag = nil
            do
            (cond
             ((eq ':error i)
              (setq onerror-flag t))
             (onerror-flag
              (setq onerror-flag nil)
              (setq d 
                    (cond
                     ((deferred-p i) 
                      (deferred:set-next d i) i)
                     ((functionp i)
                      (deferred:error d i))
                     (t
                      (error "A wrong object was given for chain : %s" i)))))
             ((deferred-p i)
              (deferred:set-next d i)
              (setq d i))
             ((functionp i)
              (setq d (deferred:nextc d i)))
             ((listp i)
              (setq d (deferred:parallelc d i)))
             (t
              (error "A wrong object was given for chain : %s" i))))))
    d))
 
;;; test

;; (setq deferred:debug t)
;; (setq deferred:queue nil)
;; (defun deferred:setTimeout (msec f) (deferred:call f))

;; (deferred:message-mark)

;; (lexical-let (ret count)
;;   (deferred:nextc 
;;   (deferred:aand
;;     (deferred:loop 5 (lambda (i) 
;;                        (push i count)
;;                        (if (eql i 3) (deferred:new (lambda (x) (push x count))))))
;;     (deferred:nextc it (lambda (x) (format "OK %s" count)))
;;     (deferred:error it (lambda (e) (format "error!!! %s" e)))
;;     )
;;   (lambda (x) (setq ret x)))
;;   (deferred:fire-queue!)
;;   ret)


(provide 'el-deferred)
;;; el-deferred.el ends here
