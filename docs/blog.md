# I wrote a test for "zero-downtime deployments". It failed three times before it worked.

### Every SRE CV claims it. Almost nobody measures it. Here is what happened when I tried.

---

I have "coordinated zero-downtime rollouts" on my CV. So does nearly every SRE
I have ever interviewed alongside. It is one of those phrases that has quietly
stopped meaning anything, because it describes an intention rather than a
measurement.

Here is what it usually means in practice: **we used a rolling update, and
nobody complained.**

Which is not the same thing. Nobody complaining is a statement about how many
users retried without mentioning it.

So I built [proofline](https://github.com/YOUR_HANDLE/proofline) — a delivery
pipeline where every deployment has to *prove* it was safe before the next
environment will accept it. Terraform provisions it, Ansible configures it,
Jenkins ships it, Kubernetes runs it. Ordinary so far. The part that isn't: a
prober runs throughout every rollout, records every single request, and **one
dropped connection fails the build.**

The interesting part is not the finished thing. It is that my test was wrong
three times, in three different ways, and each wrong version looked completely
plausible.

---

## Part 1: what "zero-downtime" actually requires

A rolling update is not zero-downtime. It is zero-downtime *if*:

- `maxUnavailable` is 0 — the default is 25%, which explicitly permits a quarter
  of your capacity to be gone mid-rollout
- readiness and liveness are **different endpoints with different meanings**
- there is a preStop hook long enough for endpoint removal to propagate
- `terminationGracePeriodSeconds` exceeds your application's drain window
- the application actually drains on SIGTERM instead of exiting
- `minReadySeconds` is long enough that a pod which passes one health check and
  then dies does not let the rollout march onward

Miss any one and you drop connections on every deploy. Silently, because nothing
is watching.

The one that catches people most often is the preStop hook, and the reason is
worth understanding rather than memorising.

When a pod is deleted, Kubernetes does two things **concurrently**: it sends
SIGTERM to the container, and it removes the pod from the Endpoints object. That
removal then propagates asynchronously to every kube-proxy and every ingress
controller in the cluster.

So there is a window — usually small, occasionally seconds — where the pod has
begun shutting down but traffic is still being routed to it. If the process
exits promptly on SIGTERM, everything arriving in that window is refused.

A `sleep 5` in a preStop hook looks like superstition. It is not. It is the pod
holding still while the rest of the cluster catches up.

The application side matters just as much:

```python
def _drain(signum, _frame) -> None:
    """Stop advertising readiness, then keep serving until the drain elapses."""
    log.info("signal %s received: draining for %ss", signum, DRAIN_SECONDS)
    _ready.clear()          # /readyz starts returning 503
    READY.set(0)

    def _exit() -> None:
        time.sleep(DRAIN_SECONDS)   # but keep serving real traffic
        os._exit(0)

    threading.Thread(target=_exit, daemon=True).start()
```

Note what liveness does *not* do here. `/healthz` keeps returning 200 the whole
time. A draining pod is not an unhealthy one, and wiring liveness to readiness
means the kubelet restarts the pod mid-drain — turning a graceful shutdown back
into dropped connections.

---

## Part 2: the prober

About 200 lines of standard-library Python. Standard library on purpose: it has
to run inside a Jenkins agent with no `pip install` step, and a dependency there
is a dependency on the worst possible day.

It sends requests at a fixed rate, records every result, and classifies the
failures:

```python
CLASS_SERVER_ERROR = "server_error"      # it answered, badly
CLASS_CONNECTION   = "connection_error"  # nothing answered at all
CLASS_TIMEOUT      = "timeout"
CLASS_CLIENT_ERROR = "client_error"      # not counted as a failure
```

That distinction matters more than it looks. A 5xx means the service is
misbehaving. A connection error means the service was not *there* — which is
what a bad rollout produces, and a categorically different thing to find in a
report.

4xx is deliberately not a failure. A client asking for something that does not
exist is not an outage, and counting it means every scanner and stale bookmark
eats your budget.

It also tracks **consecutive** failures separately from the total. Ten scattered
failures and ten in a row are very different events — the first is noise, the
second is an outage — and a report that merges them hides the interesting half.

Requests go out on a small thread pool rather than inline, so that one request
hanging for its full timeout does not stall the schedule behind it. A prober
whose own rate collapses during an outage under-reports exactly the event it
exists to measure.

---

## Part 3: three ways I got it wrong

### Wrong #1 — the prober measured itself

The first working version reached the service like this:

```bash
kubectl port-forward svc/proofline 18080:80
```

Reasonable. Wrong.

`kubectl port-forward` against a Service does **not** load-balance. It resolves
the Service to *one* backing pod and tunnels to that pod. When a rollout
replaced that pod, the tunnel died.

The results were exactly inverted:

```
make prove   (correct config)   → FAIL: 91 dropped, ~18.2s of "downtime"
make break   (unsafe config)    → PASS: 0 dropped, 100% available
```

The safe rollout "failed" because it replaced the pod my tunnel was pinned to.
The unsafe one "passed" because its tunnel happened to survive. Both numbers
looked completely believable. If I had only run the first one, I would have
spent a day debugging a preStop hook that was working perfectly.

The fix was to expose each environment on a fixed NodePort and probe that
instead. NodePort traffic goes through kube-proxy, which load-balances across
every ready endpoint — the same path real traffic takes.

**A measurement harness that does not share the production data path is
measuring itself.**

### Wrong #2 — the "broken" config wasn't broken

I built a deliberately unsafe overlay so I could watch the check fail. A check
that has never gone red in front of anyone is indistinguishable from a check
that *cannot* go red.

First attempt used the Kubernetes default:

```yaml
strategy:
  rollingUpdate:
    maxUnavailable: 25%
```

It passed. Because **percentages round down for `maxUnavailable`**, and 25% of
two replicas is 0.5, which rounds to zero. The Kubernetes default is
accidentally safe at small replica counts, and only starts dropping traffic at
four or more.

Second attempt, `maxUnavailable: 1`: one dropped request in eighty. A genuine
failure — the build correctly went red, because zero means zero — but far too
subtle to see.

Third attempt, `maxUnavailable: 100%`: still only two drops. Because with any
surge allowed, the deployment controller *prefers* to add a new pod before
removing old ones.

It needs both:

```yaml
maxUnavailable: 100%
maxSurge: 0          # forces terminate-then-create
```

Three attempts to write a configuration bad enough to break a service. That is
a strange and slightly reassuring thing to learn about Kubernetes defaults.

### Wrong #3 — the outage wasn't an error

With every pod going down at once, I expected carnage. I got this:

```
FAIL  93 requests, 2 dropped
  "availability_pct": 97.85,
  "latency_p50_ms": 3.91,
  "latency_p95_ms": 1027.57,
  "latency_p99_ms": 2067.44,
```

Two errors — and a **p99 of two seconds**, against 14ms on a healthy rollout.

Here is why. When a Service has no ready endpoints, kube-proxy has nowhere to
send the packet. The client's TCP SYN is retried until an endpoint appears, so
the request eventually **succeeds** — one or two seconds later.

An outage does not always look like an error. Sometimes it looks like everything
being slow, and an error-only check calls that a near miss.

The prober already computed p99. It just was not scoring it. Now it fails on
both:

```
FAIL  93 requests, 2 dropped
      - 2 request(s) failed (allowed 0): 2 connection_error
      - 2 consecutive failures (~0.4s of downtime)
      - p99 latency 2067.44ms exceeded 1000ms
```

This is the finding I would not have got from reading documentation. Two seconds
of every request hanging is exactly the shape of "the site froze during the
deploy" — a real user complaint that an availability dashboard reports as 100%.

---

## Part 4: the numbers

Same service. Same cluster. Same command. The only difference is configuration.

| | safe overlay | unsafe overlay |
|---|---|---|
| requests | 260 | 93 |
| dropped | **0** | 2 |
| availability | 100% | 97.85% |
| p50 | 2.83ms | 3.91ms |
| p95 | 5.94ms | 1027ms |
| **p99** | **14.64ms** | **2067ms** |
| verdict | **PASS** | **FAIL** |

Two commands:

```bash
make prove   # deploy with the safety settings, prove nothing dropped
make break   # deploy without them, watch that proof fail
```

---

## Part 5: the second gate

Dropping no traffic during the rollout is necessary, not sufficient. The deploy
could still be quietly worse than what it replaced.

So after each rollout the pipeline asks Prometheus one question: **did what I
just shipped make this environment worse?** Over a ten-minute window it compares
the error ratio against the objective in `slo/slo.yaml` and blocks promotion if:

- too many errors, or
- **not enough traffic to judge**, or
- **Prometheus returned nothing at all**

Those last two are the ones that matter, and both are ways a gate quietly stops
being a gate.

A gate that passes on silence is decoration. Ten requests and zero errors is not
evidence of a healthy deployment; it is evidence that nobody used it.

And the nastier one:

```python
value = float(result[0]["value"][1])
# A ratio with no denominator comes back as NaN. Treating NaN as a number
# would make `NaN > threshold` evaluate False and quietly pass the gate.
if value != value:
    return None
```

If the scrape is broken, or the job label is wrong, or the deployment never
became ready, a `sum(rate(...))` over an empty series returns `NaN`. **Every
comparison against NaN is false.** So `if error_ratio > max_error_ratio: block()`
passes — cleanly, precisely when your monitoring is broken.

The same idea appears in the prober. Early in development it died after two
requests because the port-forward was not up yet, recorded both as successes,
and reported 100% availability. Verdict: pass.

```python
if report.total < min_samples:
    reasons.append(
        f"only {report.total} probe(s) recorded, need at least {min_samples}; "
        "the prober did not run long enough to prove anything"
    )
```

Too few samples is a **failure**, not a pass. I would guess a meaningful share
of "we have automated verification" setups have this bug and nobody has noticed,
because the failure mode is silence.

---

## Part 6: every layer gets checked

Most portfolio pipelines have no tests at all. This one is checked at each
layer, and all of it runs in CI without a cluster or a cloud account:

| Layer | Check | Catches |
|---|---|---|
| Kubernetes | Manifests validated against **upstream JSON schemas**, strict mode | Typos and misplaced fields |
| Kustomize | Overlay references, patch targets, patch paths | Patches that apply to nothing |
| Kubernetes | Every image must name a registry | Silent falls back to Docker Hub |
| Terraform | HCL parsed; every variable described; every provider pinned | Drift between the plan you reviewed and the plan that runs |
| Ansible | `ansible-lint` at the **production** profile | Non-idempotent and unsafe tasks |
| Ansible | Playbook run twice; the second run must change nothing | Roles that only work the first time |
| Python | 36 unit tests over the prober and gate logic | The gates themselves being wrong |

The Kubernetes one deserves a moment. **`kubectl apply --dry-run=client` does
not catch a misplaced field.** Write `readinesProbe` — one missing `s` — and it
applies cleanly. Your pod has no readiness check. You find out during a rollout,
at an hour of the API server's choosing.

Validating against the upstream Kubernetes JSON schemas in strict mode catches
it in about a second:

```
FAIL deployment.yaml Deployment: spec.template.spec.containers.0:
     Additional properties are not allowed ('readinesProbe' was unexpected)
```

Two of those rows exist *because* something bit me. The registry check went in
after a pod spent twelve minutes in `ImagePullBackOff` trying to fetch
`docker.io/proofline/app` — because a bare image name silently resolves to
Docker Hub, and the error reads like an auth problem rather than a missing
prefix. The kustomize patch-path check went in after kustomize refused a patch
file that lived one directory up.

Every failure on my machine became a permanent check in the repo. That is the
part I would defend hardest in an interview.

---

## Part 7: the same ideas have different names on EC2

There is an AWS reference stack in the repo too — VPC across multiple AZs,
public ALB, private auto scaling group, ECR with immutable tags. CI validates
it; nothing applies it automatically, because applying it costs about $80/month.

The pleasing part was discovering the settings map one to one:

| Kubernetes | AWS |
|---|---|
| preStop hook | Target group `deregistration_delay` |
| `maxUnavailable: 0` | ASG instance refresh, `min_healthy_percentage = 100` |
| readinessProbe | ELB health check — **not** the EC2 health check |
| `terminationGracePeriodSeconds` | ASG lifecycle hook timeout |

The EC2 one people get wrong is health check type. An EC2 health check notices a
dead *instance*. It cannot notice an instance whose application stopped
answering — which is the failure that actually happens.
`health_check_type = "ELB"` is a one-line change that turns a fleet of
healthy-looking zombies into one that heals.

---

## Try it

```bash
git clone https://github.com/YOUR_HANDLE/proofline
cd proofline
make up      # kind cluster, registry, monitoring, app -- all local, all free
make prove   # deploy and prove no request was dropped
make break   # deploy without the safety settings and watch that proof fail
```

No cloud account needed. There is a Windows bootstrap under `hack/windows/` that
installs WSL2, Docker Engine and the whole toolchain, because that is what I run
on.

---

## What I would say about it in an interview

Not that it proves zero-downtime in production. It proves it for one service, on
one cluster, under synthetic load, at a 0.2-second probe interval. That is a
real sentence with real boundaries.

What I did not expect was how much I would learn from making the check strict.
Every "obviously fine" default I had absorbed turned out to have a specific
failure mode, and the only reason I found them is that something went red when
they were wrong.

Three times my test was confidently, plausibly wrong. That is the actual lesson,
and it applies well beyond deployments: **a check you have never watched fail is
not a check.** It is a comfort blanket with a green tick on it.

---

*I'm a Site Reliability Engineer working on monitoring, incident response and
CI/CD. I write about the infrastructure things I break on purpose so I
understand them.*
