Every agent's commands on this machine share one memory cgroup (6.1 GB); when a compile in one agent fills it, the kernel's OOM killer may kill another agent's gate run too.

On 20 November the Lua port's gate chunk `lua6_c05` stopped after 119 of its 357 models (all byte-identical) with
`ended ... rc=137` in `lua/gate/lua6_c05_times.txt`, and nothing in the run's log. `dmesg` showed why:

```
oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/process_api/.../claude-code-bash,task=mojo,pid=11205
Memory cgroup out of memory: Killed process 11205 (mojo) total-vm:10122580kB, anon-rss:5603804kB, ...
memory: usage 6119484kB, limit 6119484kB, failcnt 182851
oom-kill:constraint=CONSTRAINT_MEMCG,...,task=python3,pid=8872
Memory cgroup out of memory: Killed process 8872 (python3) total-vm:115620kB, anon-rss:54784kB, ...
```

The Mojo port's `mojo build` of its engine reached 5.6 GB (four times that day); the cgroup `claude-code-bash`, which
holds the commands of every agent here and not just one, has a 6.1 GB limit, so the Lua engine (about 50 to 480 MB)
and `gate.py` were enough to tip it over. The killer took the compiler, the cgroup was still at its limit, and it took
`gate.py` next (pid 8872, 54 MB). `free` shows 6.6 GB available on the 8 GB machine all the while: the limit is the
cgroup's, not the machine's, and `free` does not show it.

What to do: after a gate chunk ends with rc 137 and no message, look in `dmesg` for `oom-kill`; check that no engine or
`gate.py` was left running (`ps`) and that no corpus file changed (a SAVE deck killed between its run and the wrapper's
restore would leave its file changed); then resume the chunk (`gate.py --resume`) and note the kill in its times file.
An agent about to start a compile known to need several gigabytes should say so to the others first, as the corpus lock
is announced for gate runs.
