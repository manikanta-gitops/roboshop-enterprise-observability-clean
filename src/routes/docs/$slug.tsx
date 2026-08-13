import { createFileRoute, Link, notFound } from "@tanstack/react-router";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { docs, getDoc } from "@/lib/docs";

export const Route = createFileRoute("/docs/$slug")({
  loader: ({ params }) => {
    const doc = getDoc(params.slug);
    if (!doc) throw notFound();
    return doc;
  },
  head: ({ loaderData }) => {
    const title = loaderData ? `${loaderData.title} — Roboshop Review` : "Roboshop Review";
    const description = loaderData
      ? `${loaderData.title}: part of the twelve-phase enterprise DevOps architecture review of the Roboshop EKS platform.`
      : "Enterprise DevOps architecture review of the Roboshop EKS platform.";
    return {
      meta: [
        { title },
        { name: "description", content: description },
        { property: "og:title", content: title },
        { property: "og:description", content: description },
        { property: "og:type", content: "article" },
        { name: "twitter:card", content: "summary_large_image" },
      ],
    };
  },
  component: DocPage,
});

function DocPage() {
  const doc = Route.useLoaderData();
  const idx = docs.findIndex((d) => d.slug === doc.slug);
  const prev = docs[idx - 1];
  const next = docs[idx + 1];

  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="mx-auto max-w-6xl gap-12 px-6 py-12 lg:flex">
        <aside className="mb-10 lg:mb-0 lg:w-64 lg:shrink-0">
          <Link
            to="/"
            className="font-mono text-xs uppercase tracking-[0.2em] text-muted-foreground hover:text-foreground"
          >
            ← Overview
          </Link>
          <nav className="mt-6 space-y-1">
            {docs.map((d, i) => (
              <Link
                key={d.slug}
                to="/docs/$slug"
                params={{ slug: d.slug }}
                className={`block rounded-md px-3 py-2 text-sm transition-colors ${
                  d.slug === doc.slug
                    ? "bg-accent text-accent-foreground"
                    : "text-muted-foreground hover:bg-muted hover:text-foreground"
                }`}
              >
                <span className="mr-2 font-mono text-xs opacity-60">
                  {String(i + 1).padStart(2, "0")}
                </span>
                {d.title}
              </Link>
            ))}
          </nav>
        </aside>

        <article className="prose-doc min-w-0 flex-1">
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{doc.content}</ReactMarkdown>

          <div className="mt-16 flex justify-between gap-6 border-t border-border pt-6 text-sm">
            {prev ? (
              <Link
                to="/docs/$slug"
                params={{ slug: prev.slug }}
                className="text-muted-foreground hover:text-foreground"
              >
                ← {prev.title}
              </Link>
            ) : (
              <span />
            )}
            {next ? (
              <Link
                to="/docs/$slug"
                params={{ slug: next.slug }}
                className="text-right text-muted-foreground hover:text-foreground"
              >
                {next.title} →
              </Link>
            ) : (
              <span />
            )}
          </div>
        </article>
      </div>
    </main>
  );
}
