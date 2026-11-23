import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router";

import { fetchIdentityStatus, fetchMemories } from "~/lib/api";
import { buildSoul, SOUL_WIDTH } from "~/lib/soul";
import type { Identity } from "~/lib/types";

/** One identity's portrait, sized to fit a grid cell on the home page. */
function SoulPortrait({ identity }: { identity: Identity }) {
  const status = useQuery({
    queryKey: ["identity-status", identity.id],
    queryFn: () => fetchIdentityStatus(identity.id),
    refetchInterval: 5000,
  });
  const memories = useQuery({
    queryKey: ["memories", identity.id],
    queryFn: () => fetchMemories(identity.id),
  });

  if (memories.isLoading) {
    return (
      <div className="flex min-h-40 items-center justify-center rounded-lg border bg-muted/30">
        <span className="text-xs text-muted-foreground">drawing...</span>
      </div>
    );
  }

  const rows = buildSoul({
    name: identity.name,
    live: status.data?.live ?? identity.live,
    stepCount: status.data?.step_count ?? identity.step_count,
    createdAt: identity.created,
    memories: memories.data ?? [],
  });

  return (
    <Link
      to={`/i/${encodeURIComponent(identity.id)}/soul`}
      className="block rounded-lg border bg-muted/20 p-3 transition-colors hover:bg-muted/40"
      title="Open the soul page"
    >
      <div className="overflow-x-auto">
        <pre
          className="mx-auto w-fit font-mono text-[10px] leading-tight"
          style={{ minWidth: `${SOUL_WIDTH}ch` }}
        >
          {rows.join("\n")}
        </pre>
      </div>
    </Link>
  );
}

/** A portrait per identity, fed by what each mind actually holds. */
export function SoulPanel({ identities }: { identities: Identity[] }) {
  if (identities.length === 0) return null;
  return (
    <section>
      <h2 className="mb-2 font-mono text-xs font-medium uppercase tracking-wider text-muted-foreground">
        souls
      </h2>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {identities.map((identity) => (
          <SoulPortrait key={identity.id} identity={identity} />
        ))}
      </div>
    </section>
  );
}
