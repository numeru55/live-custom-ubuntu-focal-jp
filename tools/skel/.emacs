(set-language-environment 'Japanese) 
(prefer-coding-system 'utf-8) 


;; inhibit startup message 
(setq inhibit-startup-message t) 


;; カーソルの点滅を止める 
(blink-cursor-mode 0) 

 

;; ツールバーを非表示にする 
(tool-bar-mode -1) 


;; バックアップファイルをつくらない 

(setq make-backup-files nil) 
(setq auto-save-default nil) 


;; ビープ音を無くす 

(setq ring-bell-function 'ignore) 
