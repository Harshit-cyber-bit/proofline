# I wrote a test for "zero-downtime deployments." Then I had to test the test.

"Zero-downtime rollouts" is on my CV. It's on almost every SRE's CV. For most of
us it means: we used a rolling update, and nobody complained.

Nobody complaining is a statement about how many people retried without
mentioning it.

So I built something to check. A small service on Kubernetes, a prober that
hammers it through an entire rollout and counts what happens, and an SLO gate
that asks Prometheus whether the thing just deployed made the environment worse
before anything gets promoted. Terraform underneath, Ansible for the fleet,
Jenkins driving it. I called it proofline, because the point was for the
pipeline to prove its claims rather than assert them.

Then I ran it, and spent a week finding out that almost every instrument I'd
built was lying to me.

Not the service. The service was fine. **The bugs were in the things measuring
the service** — and each one produced a confident, plausible, wrong number that
I would have believed if I hadn't had a second measurement to check it against.

That turned out to be the actual lesson, and it's worth more than the project.

---

## 1. My prober was measuring itself

First run. Safe configuration — proper `maxUnavailable`, a preStop hook, a
readiness probe, a graceful drain. The prober reported **18 seconds of
downtime.**

Then I deliberately broke the deployment. Ripped out the preStop hook, set
`maxUnavailable` to a value that should take pods down in bulk, dropped the
grace period. Re-ran it.

**Zero dropped requests.**

Exactly inverted, and both numbers looked believable. The safe config could
plausibly have a gap I hadn't accounted for; the broken one could plausibly be
lucky on a small sample.

The prober reached the service with `kubectl port-forward svc/proofline`. That
looks like it targets the Service — you name a Service, after all. It doesn't.
**`port-forward` does not load-balance.** It resolves the Service to its
endpoints, picks one pod, and tunnels to that pod.

So the safe rollout — which correctly replaced pods one at a time — killed the
pod my tunnel was pinned to. The tunnel died. Eighteen seconds of "downtime"
that no real user would have experienced, because kube-proxy would have sent
them to the other pod.

And the broken rollout? It took everything down at once, the tunnel broke
instantly, `port-forward` reconnected to a new pod, and the gap fell in the
window where my prober was already erroring out and retrying. It scored
perfectly.

The fix was to expose fixed NodePorts through kind's `extraPortMappings` and
probe those, so traffic goes through kube-proxy — the path real traffic takes.

**What I'd tell myself:** a test harness that shares a failure mode with the
thing it's testing produces garbage that looks like data. The number was never
"wrong" in an obvious way. It was wrong in the direction that made a broken
config look good.

---

## 2. My "broken" configuration wasn't broken

Once the prober was honest, the broken overlay stopped dropping traffic. I had
set `maxUnavailable: 25%`, which is the Kubernetes default and felt aggressive
enough for a demo.

**`maxUnavailable` as a percentage rounds down.** At two replicas, 25% is 0.5,
which rounds to **zero**. Kubernetes was refusing to take any pod down before a
replacement was ready. My deliberately unsafe configuration was, accidentally,
completely safe.

I raised it to `1`. That dropped about one request in eighty — enough to fail a
build, too subtle to be worth recording.

It took `maxUnavailable: 100%` **and** `maxSurge: 0` to actually drop traffic.
Both. With `maxSurge` at its default, Kubernetes will happily create replacement
pods first and never leave you with nothing.

I found this genuinely reassuring. The defaults are more protective than I'd
assumed, and at small replica counts the rounding behaviour quietly makes them
stricter. But it also means: if you've never measured your rollouts, you don't
know whether your safety settings are doing anything, because the defaults may
be carrying you.

---

## 3. The outage wasn't an error

Finally, a genuinely broken rollout. Every pod down at once. I expected a wall
of connection failures.

I got **2 errors out of 93 requests.** And a p99 latency of **2,067ms**, against
a normal 15ms.

When a Service has no ready endpoints, kube-proxy has nowhere to send the
packet. It doesn't refuse the connection. The client's SYN goes unanswered, TCP
retransmits, and when a pod finally becomes ready the connection completes.

**The request succeeds. Two seconds later.**

An availability dashboard reports that outage as 100% available. Every request
returned 200. This is the single most useful thing I learned all week, and it
reframes a category of incident: "the site was slow" and "the site was down" can
be the same event seen through different instruments.

The prober now fails on a p99 ceiling as well as on dropped requests. Without
it, the most realistic outage in the whole project is invisible.

---

## 4. The SLO gate promoted a deployment the prober had just failed

This is the one that made me rewrite how I think about verification.

The pipeline has two independent checks. The prober measures from outside the
cluster, over HTTP, like a user. The SLO gate queries Prometheus, which scrapes
counters from inside the pods. Different data path, different failure modes —
which is the whole reason to have both.

I injected a 20% error rate and ran a deployment.

- **Prober:** 1,200 requests, 257 failed, 78.58% available. **FAIL.**
- **Gate:** 0.87% error ratio. **PASS. Promote to staging.**

Two measurements of the same two minutes, 25× apart. And the one that was wrong
was the gate — the component whose entire job is to stop bad deployments.

Two causes, both design rather than typo.

**The window was too long.** The gate averaged over ten minutes. The burn lasted
two. A 20% error rate for two minutes out of ten comes to about 4% — and after
the second cause below, under 1%. Under the threshold. Pass.

What makes this properly embarrassing is that the *alert rules* in the same
repository already did this correctly. They use multi-window multi-burn-rate
alerting straight out of the Google SRE Workbook: a long window to establish the
budget is really burning, a short one so the alert clears promptly. Standard
practice, implemented, sitting in `slo/rules/`.

The gate used a single window. So my alerting and my gate disagreed about the
same incident — the alerts would have paged for a release the gate promoted — in
a repo whose `slo.yaml` opens by claiming the two can't drift apart.

**Health checks were counted as user traffic.** `/healthz`, `/readyz`,
`/metrics` were all in the denominator. When I made the gate print its own
breakdown, this is what came back:

```
requests by path over 10m:
      3,169   200  /readyz     excluded from the SLI
        759   200  /api/work
        705   200  /healthz    excluded from the SLI
        463   200  /metrics    excluded from the SLI
        135   500  /api/work

      5,229  total, of which 893 is user traffic
      83% of it is health checks and metrics scrapes.
      Counting those in the SLI divides every real error by 6.
```

A readiness probe every two seconds is a guaranteed 200 that no user ever made.
It pads availability, and it pads it hardest when the service is small — which
is exactly when you're watching a deploy.

There's a second-order version of this too: a pod draining correctly returns 503
on `/readyz` while it shuts down. Counted in the SLI, a pod is charged error
budget for terminating gracefully.

After fixing both — paired 10m/2m windows, probe paths excluded — the same
scenario gives:

- **Long window:** 15.06%. **Short window:** 22.36%. **BLOCKED.**
- Prober, measured completely independently, over the same two minutes: **21.4%.**

Within a point of each other, from two entirely different measurement paths.
That agreement is the strongest evidence in the project that either of them
works.

`make burn` now **fails the build if the gate doesn't block.** A gate nobody has
watched fail isn't a gate. A gate nobody has watched fail *correctly* is worse,
because you've seen it produce output and mistaken that for it working.

---

## 5. `increase()` is fiction during a rollout

The breakdown above exposed something else. `/readyz` shows 3,169 requests over
ten minutes. The probe fires every 2 seconds against 2 pods. Ten minutes allows
about 600. `/metrics` shows 463 where a 15-second scrape interval allows about
80.

Both inflated by the same factor of five to six.

`increase()` extrapolates each time series across the full window. A rollout
replaces every pod, so a ten-minute window containing two deployments is full of
series that only existed for ninety seconds, each stretched to fill ten minutes.
The giveaway was there all along and I'd read past it: the counts came back as
`28333.28`. A non-integer number of HTTP requests.

This is why the fixed gate computes the ratio **inside Prometheus** rather than
fetching two counts and dividing in Python. Numerator and denominator inflate
together, so the ratio survives even though neither count means anything. The
proof that it works is the 22.36% vs 21.4% agreement above — the ratio was
right while the counts it came from were off by five.

Any absolute request count taken from a window containing a deploy is not a
number you should put in a report.

---

## 6. Green CI is a claim about your checker

Halfway through, the project started teaching the same lesson from the other
direction.

`ansible-lint` passed at its **production** profile — the strictest setting —
through three separate bugs that made the playbook completely non-functional.

**The inventory didn't parse.** I'd written what looked like a Docker label
filter:

```yaml
filters:
  label:
    - "proofline.role=app"
```

That option isn't a Docker label filter. It's the generic inventory-filtering
interface — a *list* of include/exclude Jinja conditions. My dict was never a
valid shape for it.

Here's the part worth remembering: **Ansible treats an unparseable inventory as
a warning.** It logs it, falls back to the implicit localhost, and runs the
playbook anyway. A configuration-management run aimed at three servers silently
retargets the machine you launched it from. I got away with it because my play
said `hosts: all`, which doesn't match implicit localhost. Change one line to
`hosts: localhost` and that playbook configures your laptop and reports success.

**The stdout callback wasn't installed.** `stdout_callback = yaml` lives in
`community.general`, which the repo deliberately doesn't depend on. It fails
*after* the play finishes, so it reads like the playbook broke.

**The first task failed with "No package matching 'curl' is available."** Which
sounds like curl doesn't exist. It means the host has never fetched a package
*list*. Container images clear `/var/lib/apt/lists` to stay small — and so does
a freshly provisioned cloud instance, so this wasn't a container quirk. The role
was broken for real hosts too.

None of these are things a linter can catch. It checks task style and syntax. It
doesn't know which collections are installed, doesn't validate an inventory
plugin's options against the plugin, and can't know anything about the target.

**Linted is not runs.** Same lesson as the SLO gate, arriving from a completely
different direction, and I'd have said I already knew it.

---

## 7. Jenkins, and five more

Before running the Jenkins stage I read the Jenkinsfile. It still probed through
`kubectl port-forward` — with a comment explaining that this was how you reach
the Service rather than a single pod.

The exact false belief from section 1, preserved in a comment, in the same repo
whose headline finding is that it's wrong. I'd fixed the Makefile days earlier
and never looked at the pipeline.

Four more in the same file, all found by reading rather than running:

- `kustomize edit set image proofline/app=...` matched nothing, because the base
  image is registry-qualified. The override would silently do nothing and the
  base default would deploy.
- `KUBECONFIG` pointed at a path nothing writes.
- `PROMETHEUS` was `http://localhost:30090` — from inside the Jenkins container,
  that's the Jenkins container.
- Every plugin in `plugins.txt` was pinned to `:latest` against a base image
  from a year earlier. The build died in fifty lines of "requires a greater
  version of Jenkins." Nothing in the repo had changed; plugin maintainers had
  shipped releases. Meanwhile `terraform/local/versions.tf` opens by explaining
  exactly why you pin your dependencies — written the same afternoon.

Then two the container found for me.

A single wrong method name in the Job DSL seed job — mixing the classic API
(`git { remote { url } }`) with the dynamic one (`scmGit { userRemoteConfigs
{ ... } }`) — didn't produce a missing job. Configuration-as-code turns a failed
job script into `ConfigurationAsCodeBootFailure`, so **Jenkins doesn't start at
all.** One typo in a job definition takes down the controller. Nobody mentions
that in the tutorials.

And my favourite of the entire project. `kubectl get nodes` inside the container
returned:

```
couldn't get current server API group list:
<html><head><meta http-equiv='refresh' content='1;url=/login?from=%2Fapi'/>
...Authentication required...
```

An HTML login page. With no kubeconfig, **kubectl falls back to its legacy
default of `http://localhost:8080`** — and inside that container, port 8080 is
Jenkins. So kubectl was querying Jenkins, Jenkins was politely asking it to log
in, and kubectl was reporting a Kubernetes API failure about a cluster that was
entirely healthy.

The last bug of the week was in a measuring instrument too. The `curl` command I
was using to check whether the Jenkins job existed returned nothing at all —
because `[` and `]` are URL-globbing metacharacters and curl was rejecting the
URL before sending it.

---

## What I actually took away

Fifteen or so real bugs. **Not one of them was in the application.** Every
single one was in something built to observe, validate, or gate the
application — the prober, the gate, the linter, the inventory, the pipeline, the
diagnostic scripts I wrote to debug the other bugs.

Three things I'd say to anyone building this kind of thing:

**Two independent measurements, or none.** Almost every bug here was caught by
one instrument disagreeing with another. The port-forward bug was caught by
results being *inverted* — a single measurement would have been believed. The
gate bug was caught by the prober. If you have one number and nothing to check
it against, you don't have a measurement, you have a claim with a decimal point.

**Make your tools fail loudly, then check that they do.** Ansible turns a broken
inventory into a warning. `NaN > 0.01` is `False` in every language, so an
unguarded NaN sails through a threshold check and passes the build. An empty
Prometheus vector divided by anything is empty — so a deployment with *zero*
errors came back as "no data" and got blocked, until I added `or vector(0)`. The
default behaviour of most tooling under "I don't know" is to proceed.

**Your verification needs verification.** This is the recursive bit and there's
no bottom to it. I wrote a diagnostic script to work out why some containers
wouldn't boot; it reported "exits" and threw away the exit code and logs — the
same mistake the containers were making. I rewrote it. The second version had a
hard gate in the middle that aborted before the useful part. Then I wrote a
script to check the Ansible inventory, and had to test *that* against a fake
`ansible-inventory` before I trusted it.

You stop when the cost of another layer exceeds the risk. But you should stop
deliberately, knowing you've stopped, rather than because the last thing you
built printed something green.

---

The repo runs on a laptop with kind and Docker — no cloud account, about forty
minutes end to end. `make prove` and `make break` are the two commands worth
watching: same service, same cluster, deployed twice, and the only difference is
configuration.

One passes. One doesn't. That's the whole idea.
