# IOHK Test Task

This repository contains my solution to the task found at:

http://f.nn.lv/od/5c/8y/CH_OTP_Test_Task(1).pdf

## Disclaimer

This is the first time I used the `distributed-process` package. I
understand that this claim probably lowers my chances, but I don't want any
confusion about my degree of proficiency with this framework. I'm quite
motivated to learn more about `distributed-process`, and I mostly figured
everything out from scratch in last few hours.

## How to build it

Clone, go to the root directory and execute:

```
$ stack build --copy-bins
```

This will also copy the `iohktt` executable to `~/.local/bin`. From there I
expect you to copy it to machines in your testing cluster.

## How to run it

You can use `--help` to learn about command line options:

```
$ iohktt --help
iohktt — fun with random numbers

Usage: iohktt COMMAND
  A solution to IOHK test task…

Available options:
  -h,--help                Show this help text

Available commands:
  slave                    Run a slave process
  master                   Run a master process
```

There are two commands (or modes):

* `slave`
* `master`

You should start slaves on slave nodes using this syntax:

```
$ iohktt slave --help
Usage: iohktt slave HOST SERVICE
  Run a slave process

Available options:
  -h,--help                Show this help text
  HOST                     Host name
  SERVICE                  Service name
```

For example:

```
$ iohktt slave 198.51.100.1 8080
```

Once all slaves are up, start master:

```
$ iohktt master --help
Usage: iohktt master HOST SERVICE [-n|--node-list NODELIST] [-k|--send-for K]
                     [-l|--wait-for L] [-s|--with-seed S]
  Run a master process

Available options:
  -h,--help                Show this help text
  HOST                     Host name
  SERVICE                  Service name
  -n,--node-list NODELIST  YAML file containing the node lists to
                           use (default: "node-list.yaml")
  -k,--send-for K          For how many seconds the system should send
                           messages (default: 30)
  -l,--wait-for L          Duration (in seconds) of the grace
                           period (default: 10)
  -s,--with-seed S         The seed to use for random number
                           generation (default: 0)
```

Note the `--node-list` option which allows to specify a YAML file with node
list. See `node-list.yaml` in the repo for an example. By default value of
`NODELIST` is `"node-list.yaml"`, so this requires you to put a file with
such name in the directory you're going to run master from. You're free to
specify a different (possibly absolute) path to the configuration file.

Example of a command for starting master node:

```
$ iohktt master 198.51.100.2 8080
```

Meaning of `--send-for`, `--wait-for`, and `--with-seed` should be clear,
they are what described in the document containing the task.

## Additional comments and clarifications

There are quite a few comments in the source code. In addition to those I'd
like to add a note about determinism of the program. It looks like
`distributed-process` in its current state does not allow to write fully
deterministic programs easily, to quote Simon Marlow (the comment is a bit
old, but I believe it is still valid):

> API we'll describe is concurrent and nondeterministic. And yet, the main
> reason to want to use distribution is to exploit the parallelism of
> running on multiple machines simultaneously. So this setting is similar to
> parallel programming using threads described in Chapter 13, except that
> here we have only message passing and no shared state for coordination.
>
> It is a little unfortunate that we have to resort to a nondeterministic
> programming model to achieve parallelism just because we want to exploit
> multiple machines. There are efforts under way to build deterministic
> programming models atop the distributed-process framework, although at the
> time of writing these projects are too experimental to include in this
> book.

So the requirement mentioned in the section 2.1 of the task:

> All the random choices made must be deterministic and seeded with a seed.
> It should be easy to re-run the program with a given seed.

although I believe is met in my solution in the sense that every node
produces a deterministic sequence of random numbers determined by the
initially chosen seed, it does not help with producing identical results
with identical seeds due to the concurrent and nondeterministic nature of
the framework. I'd like your comment on this.

For reference, here are logs of two “identical” runs (time stamps stripped
for reading ease):

```
Spawning slave processes
[nid://127.0.0.1:44445:0,nid://127.0.0.1:44446:0,nid://127.0.0.1:44447:0,nid://127.0.0.1:44448:0]
Sending initializing messages
Waiting for start of the grace period: 2017-10-10 07:36:56.564039099 UTC
Waiting for end of the grace period:   2017-10-10 07:37:26.564039099 UTC
Process pid://127.0.0.1:44447:0:9 on node nid://127.0.0.1:44447:0 finished with results: |m|=95322, sigma=2.2666084150857515e9
Process pid://127.0.0.1:44446:0:9 on node nid://127.0.0.1:44446:0 finished with results: |m|=93904, sigma=2.200674520589758e9
Process pid://127.0.0.1:44445:0:9 on node nid://127.0.0.1:44445:0 finished with results: |m|=111903, sigma=3.124078258700147e9
Process pid://127.0.0.1:44448:0:9 on node nid://127.0.0.1:44448:0 finished with results: |m|=102977, sigma=2.643822777530034e9
Time is up, killing all slaves
```

```
Spawning slave processes
[nid://127.0.0.1:44445:0,nid://127.0.0.1:44446:0,nid://127.0.0.1:44447:0,nid://127.0.0.1:44448:0]
Sending initializing messages
Waiting for start of the grace period: 2017-10-10 07:39:24.276909206 UTC
Waiting for end of the grace period:   2017-10-10 07:39:54.276909206 UTC
Process pid://127.0.0.1:44445:0:9 on node nid://127.0.0.1:44445:0 finished with results: |m|=115144, sigma=3.3053304195063634e9
Process pid://127.0.0.1:44446:0:9 on node nid://127.0.0.1:44446:0 finished with results: |m|=109520, sigma=2.997330037605579e9
Process pid://127.0.0.1:44448:0:9 on node nid://127.0.0.1:44448:0 finished with results: |m|=108338, sigma=2.929850662291255e9
Process pid://127.0.0.1:44447:0:9 on node nid://127.0.0.1:44447:0 finished with results: |m|=108328, sigma=2.9208667047378154e9
Time is up, killing all slaves
```

It looks like the work is divided fairly but the results are not identical
between the runs. Perhaps there are some additional implicit requirements I
should account for, so the seed parameter starts to make sense?

## License

Copyright © 2017 Mark Karpov

Distributed under BSD 3 clause license.
