# minibash-linux ~/.bashrc (sourced by interactive shells after login)
alias ll='ls -la'
alias svc='bashsvc'
alias status='bashsvc status'

# handy one-liner help
help() {
  cat <<'EOF'
minibash-linux quick help:
  bashsvc status            services + live pids
  bashsvc logs <service>    captured log lines (from the bdb logs table)
  bashsvc start|stop|restart <service>
  bashsvc poweroff | reboot
  bdb select services       raw database view
EOF
}
