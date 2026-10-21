#!/usr/bin/env python3
"""Run a cross build under strace and report every build script that asks what the build machine
is.

    uname-audit.py ninja -j6 -v       # build, then audit
    uname-audit.py --log uname.log    # audit an earlier trace

A cross build is told its target, so a script that still asks about the build machine is suspect:
zlib's configure took its platform from `uname -s` instead of --host, and on a mac archived an
Android build with Apple's libtool.  From a Linux build machine the answer is usually harmless, but
the question is still visible, so a cross build here catches what would only break on a mac.

Each question is attributed to the recipe and ExternalProject step that asked it: runs of the
`uname` and `arch` binaries (with their flags, and the script that ran them), and uname() syscalls
from anything not in --quiet.  Not reported, because they are supposed to describe the build
machine or decide nothing:

- gethostname(), which glibc implements as uname() and every bash calls on startup; told apart by
  the backtrace strace records.
- the build-machine description every autoconf configure writes at the top of config.log.
- config.guess working out --build, and cmake filling in CMAKE_HOST_SYSTEM_*.
- uname() at startup from cmake and meson (which take the target from the toolchain or cross file),
  find (which checks the kernel version) and tclsh (which fills in tcl_platform).  The tclsh one
  means a Tcl script's *use* of tcl_platform is invisible here.

The audit shows that a script asked, not what it did with the answer, so a new question needs
reading.  Questions reviewed and judged harmless are listed in KNOWN with the reason; a known one
that is no longer asked is reported too, so that an entry does not outlive the code it describes.

Exits non-zero if the build fails, or if anything is new or stale."""

import argparse
import re
import subprocess
import sys
from collections import Counter, defaultdict

# (recipe, asker, question) -> why it does not matter
KNOWN = {
    ('zlib', 'configure', 'uname -a'):
        'adds a GNU ld flag when the build machine is SPARC',
    ('libpcre2-8', 'configure', 'uname'):
        'assumes EBCDIC when the build machine is z/OS',
    ('libunbound', 'configure', 'uname'):
        'NetBSD and Linux build machines get flags for `make lint`, which is never run',
    ('libunbound', 'configure', 'uname -s'):
        'an MSYS2 build machine is taken as a mingw target; unbound is only built for the '
        'session-router client, which is not built for Android from Windows',
    ('icu-io', 'make', 'uname -o'):
        "mh-mingw's MSYS-vs-Cygwin path helpers, evaluated only by icuinfo and `make check`",
    ('icu-io', 'icutools.databuilder', 'uname()'):
        'converts from EBCDIC when the build machine is z/OS',
    ('icu-io-native', 'icutools.databuilder', 'uname()'):
        'converts from EBCDIC when the build machine is z/OS',
}

# --seccomp-bpf stops the tracee only for the traced syscalls, which is what keeps this cheap.  -k
# records each one's backtrace, three frames being enough to see gethostname() above uname(); it is
# also taken for execve and clone, which is most of the cost.  -s 512 keeps enough of a command line
# to find the recipe in it.
STRACE = ['strace', '-f', '--seccomp-bpf', '-k', '--stack-trace-frame-limit=3', '-e', 'signal=none',
          '-s', '512', '-e', 'trace=uname,execve,clone,clone3,fork,vfork']

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--log', default='uname-audit.log',
                help='the strace log to write, or with no command, to read (default: %(default)s)')
ap.add_argument('--quiet', default='uname,arch,cmake,meson,find,tclsh',
                help='programs whose uname() syscalls are counted, not reported')
ap.add_argument('--all', action='store_true', help='also list the known questions')
ap.add_argument('command', nargs=argparse.REMAINDER, help='the build to trace')
args = ap.parse_args()
quiet = set(args.quiet.split(','))

if args.command:
    rc = subprocess.call(STRACE + ['-o', args.log] + args.command)
    if rc != 0:
        sys.exit(rc)

# strace pads the pid to five columns, which matters in a container, where pids start at 1.
line_re = re.compile(r'^(\d+) +(.*)$')
exit_re = re.compile(r'^\+\+\+ (exited|killed)')
execve_re = re.compile(r'^execve\("([^"]*)", \[(.*?)\](?:\.\.\.)?, ')
str_re = re.compile(r'"((?:[^"\\]|\\.)*)"')
ret_re = re.compile(r'= (\d+)$')
fork_re = re.compile(r'^(?:(?:clone3?|v?fork)\(|<\.\.\. (?:clone3?|v?fork) resumed>)')
recipe_re = re.compile(r'sessiondep_(.+?)_external')
step_re = re.compile(r'sessiondep_.+?_external-stamp/sessiondep_.+?_external-(\w+)')


def name(av):
    return av[0].rsplit('/', 1)[-1] if av else '?'


# A process is keyed by (pid, lifetime), the lifetime advancing at each exit, because pids are
# reused and strace can print a child's syscalls before its parent's clone() returns -- or, for a
# vfork whose child execs and exits at once, even its exit.
life = defaultdict(int)
seen = set()
parent = {}
execs = defaultdict(list)  # key -> [(lineno, argv)]
pending_exec = {}
uname_bin = []  # (lineno, key, argv)
uname_sys = []  # (lineno, key)
last_uname = None  # the uname_sys entry the following backtrace lines belong to
hostnames = 0
root = None


def key(pid):
    return (pid, life[pid])


with open(args.log, errors='replace') as f:
    for n, raw in enumerate(f):
        if raw.startswith(' > '):
            if last_uname is not None and 'gethostname' in raw:
                uname_sys.pop()
                hostnames += 1
                last_uname = None
            continue
        last_uname = None
        m = line_re.match(raw.rstrip('\n'))
        if not m:
            continue
        pid, rest = int(m.group(1)), m.group(2)
        k = key(pid)
        seen.add(k)
        if root is None:
            root = k
            execs[k].append((-1, ['ninja']))

        if exit_re.match(rest):
            life[pid] += 1
        elif rest.startswith('execve(') or rest.startswith('<... execve resumed>'):
            em = execve_re.match(rest)
            if em:
                pending_exec[k] = str_re.findall(em.group(2))
            if rest.endswith('= 0') and k in pending_exec:
                av = pending_exec.pop(k)
                execs[k].append((n, av))
                if name(av) in ('uname', 'arch'):
                    uname_bin.append((n, k, av))
            elif ' resumed>' in rest:
                pending_exec.pop(k, None)
        elif fork_re.match(rest):
            rm = ret_re.search(rest)
            if rm:
                child = key(int(rm.group(1)))
                # A child that has already exited left its pid on a lifetime with nothing in it yet.
                earlier = (child[0], child[1] - 1)
                if child not in seen and child[1] > 0 and earlier not in parent:
                    child = earlier
                parent[child] = (k, n)
        elif rest.startswith('uname(') or rest.startswith('<... uname resumed>'):
            if rest.startswith('uname(') and rest.endswith('<unfinished ...>'):
                continue
            uname_sys.append((n, k))
            last_uname = len(uname_sys) - 1


def argv_at(k, n):
    """k's command line as of line n: its last exec before then, else what it inherited."""
    while k is not None:
        before = [av for ln, av in execs.get(k, ()) if ln < n]
        if before:
            return before[-1]
        p = parent.get(k)
        if p is None:
            return ['?']
        k, n = p
    return ['?']


def chain(k, n):
    """[(key, argv)] from k up to, not including, ninja."""
    out = []
    while k is not None and k != root:
        out.append((k, argv_at(k, n)))
        k = parent.get(k, (None, 0))[0]
    return out


def where(ch):
    """(recipe, step) of the ninja command a chain descends from."""
    top = ' '.join(ch[-1][1]) if ch else ''
    rm = recipe_re.search(top)
    if not rm:
        return '(no recipe)', ' '.join(ch[-1][1][:3]) if ch else '?'
    # The step comes from the stamp the command touches last, which -s truncates off a long one.
    sm = step_re.search(top)
    return rm.group(1), sm.group(1) if sm else '?'


def who(av):
    """What is asking: the script an interpreter runs, or a python module, else the program."""
    prog = name(av)
    rest = [a for a in av[1:] if not a.startswith('-')]
    if prog.startswith('python') and '-m' in av[1:]:
        return av[av.index('-m') + 1]
    if prog in ('bash', 'sh', 'dash', 'tclsh', 'perl') or prog.startswith('python'):
        return rest[0].rsplit('/', 1)[-1] if rest else prog
    return prog


def short(av, n=4):
    s = ' '.join(av[:n])
    return s if len(av) <= n else s + ' …'


# The asker is the nearest ancestor that is neither uname nor a subshell of the same script, so
# that every `$(uname ...)` a script runs groups under the one process running that script.
asks = defaultdict(list)  # asker key -> [(where, asker argv, question)]
for n, k, av in uname_bin:
    ch = chain(k, n + 1)
    i = next((i for i, (_, c) in enumerate(ch) if i > 0 and name(c) not in ('uname', 'arch')), None)
    question = ' '.join([name(av)] + av[1:])
    if i is None:
        asks[None].append((where(ch), ['?'], question))
        continue
    while i + 1 < len(ch) and ch[i + 1][1] == ch[i][1]:
        i += 1
    asks[ch[i][0]].append((where(ch), ch[i][1], question))

autoconf_header = ['uname -m', 'uname -r', 'uname -s', 'uname -v', 'uname -p', 'uname -X', 'arch',
                   'arch -k']
expected = defaultdict(Counter)  # (recipe, step) -> what
found = Counter()  # (recipe, asker, question) -> count
example = {}  # (recipe, asker, question) -> (step, asker argv)


def note(w, asker_av, question):
    k = (w[0], who(asker_av), question)
    found[k] += 1
    example.setdefault(k, (w[1], asker_av))


for calls in asks.values():
    w, asker_av, _ = calls[0]
    questions = [q for _, _, q in calls]
    asker = who(asker_av)
    if asker.endswith('.guess'):
        expected[w][asker] += 1
        continue
    if asker == 'configure' and 'uname -X' in questions:
        for q in autoconf_header:
            if q in questions:
                questions.remove(q)
        expected[w]['config.log header'] += 1
    if asker == 'cmake' and set(questions) <= {'uname -m', 'uname -r'}:
        expected[w]['CMAKE_HOST_SYSTEM_*'] += 1
        continue
    for q in questions:
        cw, cav, _ = next(c for c in calls if c[2] == q)
        note(cw, cav, q)

hushed = Counter()
for n, k in uname_sys:
    ch = chain(k, n)
    me = ch[0][1] if ch else ['?']
    if name(me) in quiet or (name(me).startswith('python') and any('mesonbuild' in a for a in me)):
        hushed[name(me)] += 1
        continue
    note(where(ch), me, 'uname()')

print(f'{len(uname_bin)} uname/arch runs, {len(uname_sys) + hostnames} uname() syscalls '
      f'({hostnames} gethostname(); counted only: '
      + ', '.join(f'{p} {c}' for p, c in hushed.most_common()) + ')')
print(f'{sum(len(v) for v in expected.values())} build-machine descriptions in '
      f'{len({r for r, _ in expected})} recipes, as expected')

new = sorted(k for k in found if k not in KNOWN)
known = sorted(k for k in found if k in KNOWN)
built = {r for r, _ in expected} | {r for r, _, _ in found}
gone = sorted(k for k in KNOWN if k not in found and k[0] in built)


def show(k):
    step, av = example[k]
    return f'  {k[0]} [{step}]: {k[2]} ×{found[k]}, asked by {short(av, 6)[:200]}'


if new:
    print(f'\nNEW — {len(new)} question(s) not reviewed yet; read what the script does with the answer,'
          f' then fix the recipe or add to KNOWN in {sys.argv[0]}:')
    for k in new:
        print(show(k))
if gone:
    print(f'\nSTALE — {len(gone)} known question(s) no longer asked; remove from KNOWN:')
    for k in gone:
        print(f'  {k[0]}: {k[1]} {k[2]}')
if args.all and known:
    print(f'\nknown — {len(known)}:')
    for k in known:
        print(show(k))
        print(f'      {KNOWN[k]}')
if not new and not gone:
    print(f'\nclean: {len(known)} known question(s), nothing new')
sys.exit(1 if new or gone else 0)
