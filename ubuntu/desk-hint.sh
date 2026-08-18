# desk-hint.sh — reminds the person to set their own password, until they have.
#
# INSTALL IN TWO PLACES. /etc/profile.d alone is not enough: it is read by LOGIN shells
# only, and a GNOME Terminal window is an interactive NON-login shell, so a desktop user
# would never see this.
#
#   install -m 644 desk-hint.sh /etc/profile.d/desk-hint.sh
#   echo '[ -r /etc/profile.d/desk-hint.sh ] && . /etc/profile.d/desk-hint.sh' >> /etc/zsh/zshrc
#   echo '[ -r /etc/profile.d/desk-hint.sh ] && . /etc/profile.d/desk-hint.sh' >> /etc/bash.bashrc
#
# It goes quiet permanently once desk-passwd has run for this user, so it nags exactly as
# long as it needs to and never becomes terminal noise.

case $- in
  *i*) ;;
  *) return 2>/dev/null || exit 0 ;;
esac

if [ -n "${HOME:-}" ] && [ ! -f "$HOME/.config/desk-passwd-done" ]; then
  printf '\n  \033[1mSet your own password:  desk-passwd\033[0m\n'
  printf '  It changes your login AND your remote-desktop password together.\n'
  printf '  Do NOT use "passwd", and do NOT use Settings > Users: each changes only\n'
  printf '  one of the two, which breaks remote desktop.\n\n'
fi
