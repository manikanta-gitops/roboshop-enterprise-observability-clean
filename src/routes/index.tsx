import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Roboshop Platform — Enterprise DevOps Architecture Review" },
      {
        name: "description",
        content:
          "A 12-phase enterprise review of the Roboshop EKS platform: architecture, Terraform, Kubernetes, GitOps, CI/CD, security, observability and production readiness.",
      },
      { property: "og:title", content: "Roboshop Platform — Enterprise DevOps Architecture Review" },
      {
        property: "og:description",
        content:
          "Scorecard, findings and remediation across infrastructure, delivery, security and resilience.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

const phases = [
  { n: "01", t: "Executive Review", f: "docs/00-executive-review.md", d: "Architecture, strengths, 24 weaknesses, security findings, full scorecard." },
  { n: "02", t: "Repository Restructure", f: "docs/01-repo-structure.md", d: "Enterprise folder tree, why each folder exists, safe migration plan." },
  { n: "03", t: "Terraform / IaC", f: "docs/02-terraform.md", d: "5-layer state model, VPC, EKS, IRSA, ECR, KMS, deployment order, cost." },
  { n: "04", t: "Kubernetes & Helm", f: "docs/03-kubernetes.md", d: "Library chart, probes, QoS, HPA, PDB, storage, NetworkPolicy, stateful HA." },
  { n: "05", t: "GitOps", f: "docs/04-gitops.md", d: "Three P0 ArgoCD bugs fixed, AppProject guardrails, waves, hooks, OCI." },
  { n: "06", t: "CI/CD", f: "docs/05-cicd.md", d: "29 stages, matrix app CI, image signing, GitOps write-back, promotion." },
  { n: "07", t: "DevSecOps", f: "docs/06-security.md", d: "Four gates, Kyverno policies, Falco rules, SBOM, supply chain, kube-bench." },
  { n: "08", t: "Observability", f: "docs/07-observability.md", d: "RED/USE, SLOs, burn-rate alerts, Loki, OTel tracing across RabbitMQ." },
  { n: "09", t: "Production Readiness", f: "docs/08-production-readiness.md", d: "HA, DR with RTO/RPO, cost, upgrades, canary, full checklist." },
  { n: "10", t: "Documentation Set", f: "docs/09-documentation.md", d: "README, ADRs, runbook, troubleshooting matrix, 90-second pitch." },
  { n: "11", t: "Prerequisites", f: "docs/10-prerequisites.md", d: "Tooling, AWS services, IAM, GitHub secrets/variables, backend setup." },
  { n: "12", t: "Execution Roadmap", f: "docs/11-roadmap.md", d: "12 phases with goals, validation, interview questions, mistakes." },
  { n: "13", t: "Implementation", f: "docs/12-implementation.md", d: "Monorepo layout, Terraform modules, CI pipelines, ArgoCD fixes." },
  { n: "14", t: "SDLC & Release", f: "docs/13-sdlc-release.md", d: "Trunk-based git flow, SemVer releases, promotion, rollback." },
  { n: "15", t: "Operational Practices", f: "docs/14-operations.md", d: "Retention, TF state, env protection, smoke tests, alerts, backup/restore." },
];

const scores: [string, number][] = [
  ["Helm / K8s packaging", 9],
  ["Containerisation", 8],
  ["Secrets management", 8],
  ["Architecture", 7],
  ["Documentation", 7],
  ["CI (platform)", 6],
  ["GitOps", 4],
  ["Security (runtime)", 4],
  ["High availability", 3],
  ["Cost optimisation", 2],
  ["Disaster recovery", 1],
  ["Infrastructure as Code", 1],
  ["Observability", 0],
  ["CI (application)", 0],
];

function Bar({ v }: { v: number }) {
  const tone = v >= 7 ? "bg-chart-2" : v >= 4 ? "bg-chart-4" : "bg-destructive";
  return (
    <div className="h-1.5 w-full rounded-full bg-muted">
      <div className={`h-1.5 rounded-full ${tone}`} style={{ width: `${v * 10}%` }} />
    </div>
  );
}

function Index() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <section className="mx-auto max-w-5xl px-6 py-20">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-muted-foreground">
          roboshop_prod-dev · 340 files · 11 charts · 4 environments
        </p>
        <h1 className="mt-5 text-4xl font-semibold tracking-tight sm:text-5xl">
          Enterprise DevOps Architecture Review
        </h1>
        <p className="mt-5 max-w-2xl text-lg text-muted-foreground">
          A twelve-phase Staff-Engineer review of the Roboshop EKS platform — architecture,
          infrastructure, delivery, security, observability and production readiness.
        </p>

        <div className="mt-10 flex flex-wrap gap-4">
          <div className="rounded-xl border border-border bg-card px-6 py-4">
            <div className="text-3xl font-semibold">4.3<span className="text-muted-foreground text-lg">/10</span></div>
            <div className="text-xs text-muted-foreground">Production readiness</div>
          </div>
          <div className="rounded-xl border border-border bg-card px-6 py-4">
            <div className="text-3xl font-semibold text-destructive">6</div>
            <div className="text-xs text-muted-foreground">P0 defects found</div>
          </div>
          <div className="rounded-xl border border-border bg-card px-6 py-4">
            <div className="text-3xl font-semibold">12</div>
            <div className="text-xs text-muted-foreground">Security findings</div>
          </div>
        </div>

        <blockquote className="mt-10 border-l-2 border-primary pl-5 text-base italic text-muted-foreground">
          A very good Helm repository pretending to be a platform. The packaging layer is
          senior-level work; infrastructure, delivery, observability and resilience are missing
          or broken.
        </blockquote>
      </section>

      <section className="border-y border-border bg-card/40">
        <div className="mx-auto grid max-w-5xl gap-x-10 gap-y-5 px-6 py-14 sm:grid-cols-2">
          {scores.map(([label, v]) => (
            <div key={label}>
              <div className="mb-1.5 flex items-baseline justify-between text-sm">
                <span>{label}</span>
                <span className="font-mono text-muted-foreground">{v}/10</span>
              </div>
              <Bar v={v} />
            </div>
          ))}
        </div>
      </section>

      <section className="mx-auto max-w-5xl px-6 py-16">
        <h2 className="text-sm font-medium uppercase tracking-[0.2em] text-muted-foreground">
          The fifteen phases
        </h2>
        <ul className="mt-8 divide-y divide-border">
          {phases.map((p) => (
            <li key={p.n}>
              <Link
                to="/docs/$slug"
                params={{ slug: p.f.replace("docs/", "").replace(".md", "") }}
                className="group flex gap-6 py-5 transition-colors hover:bg-muted/40"
              >
                <span className="font-mono text-sm text-muted-foreground">{p.n}</span>
                <div>
                  <h3 className="font-medium group-hover:underline">{p.t}</h3>
                  <p className="mt-1 text-sm text-muted-foreground">{p.d}</p>
                  <code className="mt-1.5 inline-block font-mono text-xs text-muted-foreground/70">
                    {p.f}
                  </code>
                </div>
              </Link>
            </li>
          ))}
        </ul>
        <p className="mt-10 text-sm text-muted-foreground">
          Every phase is readable in full above; the same write-ups live as markdown in the{" "}
          <code className="font-mono">docs/</code> directory of this project.
        </p>

      </section>
    </main>
  );
}
