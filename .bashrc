# If not running interactively, don't do anything
[ -z "$PS1" ] && return

export VISUAL=vim
export EDITOR="$VISUAL"

# Don't put duplicate lines in the history and do not add lines that start with a space
# I want to see if turning off dups will allow me to always have my commands duplicated on every new terminal
#HISTCONTROL=erasedups:ignoredups:ignorespace
HISTCONTROL=ignorespace

# Ignore history, ls, ps, and exit commands in history file
HISTIGNORE="&:history;ls:ls * ps:ps -A:[bf]g:exit"

HISTSIZE=20000

# Keep around 128K lines of history in file
HISTFILESIZE=131072

# Appeneds to history instead of overwriting
shopt -s histappend

# Check the window size after each command and, if necessary,
# Update the values of LINES and COLUMNS.
shopt -s checkwinsize

# Lists any stopped or running jobs before exiting. requires two exits
shopt -s checkjobs

# Use extra globbing features.ie !(foo), ?(bar|baz)...  See man bash, search extglob
shopt -s extglob

# Include .files when globbing or pattern matching
shopt -s dotglob

# When a glob expands to nothing, make it an empty string instead of the literal characters
#shopt -s nullglob

# Fix spelling errors for cd, only in interactive shell
shopt -s cdspell

# Fix small errors in directory names during completion
shopt -s dirspell

# Check that hashed commands still exist before running them
shopt -s checkhash

# Allow double-start globs to match files and recursive paths
shopt -s globstar

# Auto change directory
shopt -s autocd

# Don't assume a word with a @ in it is a hostname
shopt -u hostcomplete

# Don't complete a Tab press on an empty line with every possible command
shopt -s no_empty_cmd_completion

# Use programmable completion, if available
shopt -s progcomp

# Protects from accidentally destroy content with the redirect (>) command. ie echo "test" > whatever.txt. Should be overwritable using >|. ie echo "test" >| whatever.txt.
set -o noclobber

s() { # do sudo, or sudo the last command if no arguments given
    if [[ $# == 0 ]]; then
        sudo $(history -p '!!')
    else
        sudo "$@"
    fi
}

# Set variable identifying the chroot you work in (used in the prompt below)
# I don't think this is needed in an Arch build
#if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
#    debian_chroot=$(cat /etc/debian_chroot)
#fi

# Set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color) color_prompt=yes;;
esac

# Force color
force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

# Based off of Manjaro. Set color RED for root and a different color for user. Place in both users home dir.
if [[ ${EUID} == 0 ]]; then
	PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;31m\]\w\[\033[00m\]\$ '
else
    PS1='\[\033[01;30m\]\u@\h\[\033[00m\]:\[\033[01;30m\]\w\[\033[00m\]\$ '
fi

unset color_prompt force_color_prompt

# Enable bash completion in interactive shells
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Sudo hint
if [ ! -e "$HOME/.sudo_as_admin_successful" ] && [ ! -e "$HOME/.hushlogin" ] ; then
    case " $(groups) " in *\ admin\ *)
    if [ -x /usr/bin/sudo ]; then
	cat <<-EOF
	To run a command as administrator (user "root"), use "sudo <command>".
	See "man sudo_root" for details.
	
	EOF
    fi
    esac
fi

# If the command-not-found package is installed, use it
if [ -x /usr/lib/command-not-found -o -x /usr/share/command-not-found/command-not-found ]; then
	function command_not_found_handle {
	        # Check because c-n-f could've been removed in the meantime
                if [ -x /usr/lib/command-not-found ]; then
		   /usr/lib/command-not-found -- "$1"
                   return $?
                elif [ -x /usr/share/command-not-found/command-not-found ]; then
		   /usr/share/command-not-found/command-not-found -- "$1"
                   return $?
		else
		   printf "%s: command not found\n" "$1" >&2
		   return 127
		fi
	}
fi

if [ -x /usr/bin/dircolors ]; then
	test -r ~/.dicolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
	alias ls='ls --color=auto'
	alias ll='ls -lha --color=auto'
	alias dir='dir --color=auto'
	alias vdir='vdir --color=auto'
	alias grep='grep --color=auto'
	alias fgrep='fgrep --color=auto'
	alias egrep='egrep --color=auto'
	alias diff='diff --color=auto'
fi

# Alias for quick directory moving
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# Alias for exit due to my fat fingering
alias exi="exit"
alias exti="exit"
alias xit="exit"

# Alias for Git committing and pushing. gitsync pulls all git in current folder
alias gitc="git add . && git commit -m" # + commit message
alias gitp="git push" # + remote & branch names
alias gitsync="ls | xargs -P10 -I{} git -C {} pull"
alias gitr='git add . && git commit -m "new commit" && git push' # add, commit, and push alias

# Changes dir color in terminal or tty (30:black, 31:red, 32:green, 33:yellow, 34:blue, 35:purple, 36:cyan, 37:white)
# Use di=1;4;33 to make directories (1) bold, (4) underlined, and (33) yellow
LS_COLORS="di=1;33"

# move and go to the directory
mvg ()
{
    if [ -d "$2" ];then
        mv $1 $2 && cd $2
    else
        mv $1 $2
    fi
}

# Add $HOME/bin to path
export PATH=/home/waynes/bin:$PATH

#screenfetch
#neofetch --colors 129 7 129 129 7 7 --ascii_colors 129 129 --ascii_distro arch --color_blocks off
fastfetch

# Powerline
if [ -f /usr/share/powerline/bindings/bash/powerline.sh ]; then
  powerline-daemon -q
  POWERLINE_BASH_CONTINUATION=1
  POWERLINE_BASH_SELECT=1
  source /usr/share/powerline/bindings/bash/powerline.sh
fi

# Ranger shell function wrapper
ranger() {
    local tempfile="$(mktemp -t tmp.XXXXXX)"
    command ranger --choosedir="$tempfile" "$@"
    if [ -f "$tempfile" ]; then
        local destdir="$(cat "$tempfile")"
        rm -f "$tempfile"
        if [ -n "$destdir" ] && [ "$destdir" != "$PWD" ]; then
            cd "$destdir"
        fi
    fi
}

# ls after cd
function cd {
    if [ -z "$1" ]; then
        builtin cd
    else
        builtin cd "$1"
    fi
    if [ $? -eq 0 ]; then
        ls
    fi
}


# Enable for GUI.
#xset b off
