const modules = import.meta.glob("../../docs/*.md", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

export type Doc = {
  slug: string;
  title: string;
  order: string;
  content: string;
};

export const docs: Doc[] = Object.entries(modules)
  .map(([path, content]) => {
    const file = path.split("/").pop()!.replace(/\.md$/, "");
    const [order = "", ...rest] = file.split("-");
    const heading = content.match(/^#\s+(.+)$/m)?.[1]?.trim();
    return {
      slug: file,
      order,
      title: heading ?? rest.join(" "),
      content,
    };
  })
  .sort((a, b) => a.slug.localeCompare(b.slug));

export function getDoc(slug: string): Doc | undefined {
  return docs.find((d) => d.slug === slug);
}
