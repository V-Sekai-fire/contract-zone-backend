"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

import type { FC } from "react";

// After the due time passes, wait this long for the poll to land, then re-fetch.
const graceMs = 5_000;
// While a poll is overdue, re-fetch at this pace until a newer one shows up.
const retryMs = 15_000;

const size = 64;
const stroke = 6;
const radius = (size - stroke) / 2;
const circumference = 2 * Math.PI * radius;

function clock(totalSeconds: number) {
	const s = Math.max(0, Math.ceil(totalSeconds));
	const minutes = Math.floor(s / 60);
	const seconds = s % 60;
	return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function ago(seconds: number) {
	if (seconds < 60) return "just now";
	const minutes = Math.floor(seconds / 60);
	return minutes === 1 ? "1 minute ago" : `${minutes} minutes ago`;
}

/**
 * How long until the server list refreshes: a ring that empties as the next poll
 * approaches, the time left as m:ss, and when the list was last updated. When the
 * poll is due it re-fetches the page, so the counts update without a reload.
 */
export const RefreshRing: FC<{
	polledAt: string | null;
	nextPollAt: string | null;
	intervalSeconds: number;
}> = ({ polledAt, nextPollAt, intervalSeconds }) => {
	const router = useRouter();
	const [now, setNow] = useState<number | null>(null);

	useEffect(() => {
		setNow(Date.now());
		const id = setInterval(() => setNow(Date.now()), 1_000);
		return () => clearInterval(id);
	}, []);

	const due = nextPollAt ? Date.parse(nextPollAt) : null;

	useEffect(() => {
		if (due === null) return;
		const wait = Math.max(due + graceMs - Date.now(), 0);
		let retry: ReturnType<typeof setInterval> | undefined;
		const first = setTimeout(() => {
			router.refresh();
			retry = setInterval(() => router.refresh(), retryMs);
		}, wait);
		return () => {
			clearTimeout(first);
			if (retry) clearInterval(retry);
		};
	}, [due, router]);

	if (due === null || polledAt === null) {
		return (
			<p className="text-base opacity-75" role="status">
				Waiting for the first poll…
			</p>
		);
	}

	// Before hydration, render the full ring and the whole interval so the server
	// and client markup agree.
	const remaining = now === null ? intervalSeconds : (due - now) / 1_000;
	const overdue = remaining <= 0;
	// Overdue shows a full pulsing ring, so "refreshing" never looks like an empty, idle one.
	const fraction = overdue
		? 1
		: Math.min(Math.max(remaining / intervalSeconds, 0), 1);
	const sinceSeconds =
		now === null ? 0 : Math.max(0, (now - Date.parse(polledAt)) / 1_000);

	return (
		<div
			aria-label={
				overdue
					? "Refreshing the server list"
					: `Next refresh in ${clock(remaining)}`
			}
			className="flex items-center gap-4"
			role="timer"
		>
			<div className="relative size-16 shrink-0">
				<svg
					aria-hidden
					className="size-16 -rotate-90"
					viewBox={`0 0 ${size} ${size}`}
				>
					<circle
						className="stroke-tertiary-200"
						cx={size / 2}
						cy={size / 2}
						fill="none"
						r={radius}
						strokeWidth={stroke}
					/>
					<circle
						className={`${overdue ? "animate-pulse stroke-amber-500" : "stroke-blue-500"} transition-[stroke-dashoffset] duration-1000 ease-linear motion-reduce:transition-none`}
						cx={size / 2}
						cy={size / 2}
						fill="none"
						r={radius}
						strokeDasharray={circumference}
						strokeDashoffset={circumference * (1 - fraction)}
						strokeLinecap="round"
						strokeWidth={stroke}
					/>
				</svg>
				<span className="absolute inset-0 flex items-center justify-center text-sm font-medium tabular-nums">
					{overdue ? "…" : clock(remaining)}
				</span>
			</div>
			<div className="flex flex-col text-base">
				<span className="font-medium">
					{overdue
						? "Refreshing…"
						: `Next refresh in ${clock(remaining)}`}
				</span>
				<span className="opacity-75">
					Updated {ago(sinceSeconds)} · every{" "}
					{Math.round(intervalSeconds / 60)} minutes
				</span>
			</div>
		</div>
	);
};
