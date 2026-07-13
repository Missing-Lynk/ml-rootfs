# Interactive-shell niceties for the open Artosyn rootfs (sourced by /etc/profile on
# login). Busybox-ash safe; no util-linux/coreutils deps.

# Colored ls + common shortcuts (busybox ls supports --color).
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'

# Pager: busybox provides a `less` applet, so this needs no `less` package.
export PAGER=less
export LESS='-R'

# Prompt: user@host + booted UBI volume, so it is always obvious which image/slot you
# are on (e.g. rootfs on slot B).
_ml_boot="$(sed -n 's/.*root=ubi:\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)"
[ -n "$_ml_boot" ] || _ml_boot='?'
PS1="[\\u@\\h ${_ml_boot} \\w]\\$ "
unset _ml_boot

# Status banner on interactive login.
case "$-" in
	*i*)
		[ -x /usr/local/bin/ml-info ] && /usr/local/bin/ml-info
		;;
esac
