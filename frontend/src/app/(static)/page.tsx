import { lobbyServers } from "~/api";
import { InlineLink } from "~/components/link";

import { Footer } from "../footer";

import { Section, SectionTitle } from "./section";

import type { Metadata } from "next";

// The list changes with every poll, so render it per request.
export const dynamic = "force-dynamic";

export const metadata: Metadata = { title: "OMI Lobby" };

type LobbyReply = NonNullable<Awaited<ReturnType<typeof lobbyServers>>["data"]>;
type LobbyServer = LobbyReply["servers"][number];

const platforms = [
	{ key: "basis", label: "Basis", home: "https://basisvr.org/" },
	{ key: "overte", label: "Overte", home: "https://overte.org/" }
] as const;

function players(server: LobbyServer) {
	if (server.online == null) return "?";
	return server.capacity
		? `${server.online} / ${server.capacity}`
		: String(server.online);
}

const statusClass: Record<string, string> = {
	down: "text-red-700",
	unknown: "text-neutral-500",
	up: "text-green-700"
};

function ServerTable({ servers }: { servers: Array<LobbyServer> }) {
	if (servers.length === 0)
		return <p className="opacity-75">No servers listed yet.</p>;

	return (
		<div className="overflow-x-auto">
			<table className="w-full text-left text-base">
				<thead>
					<tr className="border-b border-tertiary-300">
						<th className="p-2 font-medium">Server</th>
						<th className="p-2 font-medium">Players</th>
						<th className="p-2 font-medium">Status</th>
						<th className="p-2 font-medium">Address</th>
						<th className="p-2 font-medium">Message</th>
					</tr>
				</thead>
				<tbody>
					{servers.map((server) => (
						<tr
							className="border-b border-tertiary-200"
							key={`${server.platform}:${server.address}:${server.name}`}
						>
							<td className="p-2">{server.name}</td>
							<td className="p-2 tabular-nums">{players(server)}</td>
							<td className={`p-2 ${statusClass[server.status] ?? ""}`}>
								{server.status}
							</td>
							<td className="p-2">
								<code className="text-sm">{server.address}</code>
							</td>
							<td className="p-2 opacity-75">{server.motd}</td>
						</tr>
					))}
				</tbody>
			</table>
		</div>
	);
}

export default async function LobbyPage() {
	const { data, error } = await lobbyServers();
	const servers = data?.servers ?? [];
	const minutes = data ? Math.round(data.poll_interval_s / 60) : null;

	return (
		<main className="mx-auto flex w-full max-w-screen-lg flex-col gap-4 px-4 lg:pt-16">
			<Section className="py-8">
				<h1 className="text-3xl font-medium">OMI Lobby</h1>
				<p className="text-lg">
					Open metaverse servers you can join.
					{minutes ? ` Player counts are polled every ${minutes} minutes.` : ""}
				</p>
				{error || !data ? (
					<p className="text-red-700">The server list is unavailable right now.</p>
				) : null}
			</Section>
			{platforms.map(({ key, label, home }) => {
				const rows = servers.filter((server) => server.platform === key);
				const up = rows.filter((server) => server.status === "up").length;

				return (
					<Section key={key}>
						<SectionTitle>
							<InlineLink href={home}>{label}</InlineLink>
							<span className="text-base opacity-75">
								{up} up of {rows.length}
							</span>
						</SectionTitle>
						<ServerTable servers={rows} />
					</Section>
				);
			})}
			<Footer />
		</main>
	);
}
