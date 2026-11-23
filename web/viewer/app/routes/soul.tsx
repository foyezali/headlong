import { useQuery } from "@tanstack/react-query";
import { useParams } from "react-router";

import { IdentityTabs } from "~/components/identity-tabs";
import { LoadingDots } from "~/components/ui/loading-dots";
import { fetchIdentities, fetchIdentityStatus, fetchMemories } from "~/lib/api";
import { buildSoul, SOUL_WIDTH } from "~/lib/soul";

export function meta() {
  return [{ title: "Headlong · soul" }];
}

export default function SoulPage() {
  const { identityId = "" } = useParams();
  const identityQuery = useQuery({
    queryKey: ["identities"],
    queryFn: fetchIdentities,
  });
  const status = useQuery({
    queryKey: ["identity-status", identityId],
    queryFn: () => fetchIdentityStatus(identityId),
    refetchInterval: 5000,
  });
  const memories = useQuery({
    queryKey: ["memories", identityId],
    queryFn: () => fetchMemories(identityId),
  });

  const identity = (identityQuery.data ?? []).find((item) => item.id === identityId);
  const name = identity?.name ?? identityId.split("~").pop() ?? identityId;
  const loading = status.isLoading || memories.isLoading;

  const rows = loading
    ? []
    : buildSoul({
        name,
        live: status.data?.live ?? false,
        stepCount: status.data?.step_count ?? 0,
        createdAt: identity?.created ?? null,
        memories: memories.data ?? [],
      });

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6 px-4">
      <IdentityTabs
        identityId={identityId}
        live={status.data?.live ?? false}
        active="soul"
        name={name}
      />
      {loading ? (
        <div className="flex justify-center py-20">
          <LoadingDots />
        </div>
      ) : (
        <div className="rounded-xl border bg-muted/30 p-6">
          <div className="overflow-x-auto">
            <pre
              className="mx-auto w-fit font-mono text-xs leading-relaxed sm:text-sm"
              style={{ minWidth: `${SOUL_WIDTH}ch` }}
            >
              {rows.join("\n")}
            </pre>
          </div>
        </div>
      )}
    </div>
  );
}
