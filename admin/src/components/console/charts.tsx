import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { ChartTooltip } from './ChartTooltip';
import { chartAxisProps, chartGridProps, protocolColors } from './chart-theme';
import styles from './charts.module.css';

export type RequestPoint = { t: string; http2: number; http3: number };
export type BandwidthPoint = { t: string; ingress: number; egress: number };
export type ShareItem = { name: string; value: number; color: string };

const margin = { left: -18, right: 4, top: 8 } as const;

export function RequestsChart({ data, height = 240 }: { data: RequestPoint[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={margin}>
        <defs>
          <linearGradient id="dash-fill-h3" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={protocolColors.h3} stopOpacity={0.4} />
            <stop offset="100%" stopColor={protocolColors.h3} stopOpacity={0} />
          </linearGradient>
          <linearGradient id="dash-fill-h2" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={protocolColors.h2} stopOpacity={0.35} />
            <stop offset="100%" stopColor={protocolColors.h2} stopOpacity={0} />
          </linearGradient>
        </defs>
        <CartesianGrid {...chartGridProps} />
        <XAxis dataKey="t" {...chartAxisProps} />
        <YAxis {...chartAxisProps} allowDecimals />
        <Tooltip content={<ChartTooltip valueFormatter={(v) => `${v.toFixed(1)}/s`} />} />
        <Area type="monotone" dataKey="http3" name="HTTP/3" stroke={protocolColors.h3} strokeWidth={2} fill="url(#dash-fill-h3)" isAnimationActive={false} />
        <Area type="monotone" dataKey="http2" name="HTTP/2" stroke={protocolColors.h2} strokeWidth={2} fill="url(#dash-fill-h2)" isAnimationActive={false} />
      </AreaChart>
    </ResponsiveContainer>
  );
}

export function BandwidthChart({
  data,
  unit = 'MB/s',
  height = 240,
}: {
  data: BandwidthPoint[];
  unit?: string;
  height?: number;
}) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} margin={margin}>
        <CartesianGrid {...chartGridProps} />
        <XAxis dataKey="t" {...chartAxisProps} />
        <YAxis {...chartAxisProps} unit={unit ? ` ${unit}` : undefined} width={64} />
        <Tooltip
          cursor={{ fill: 'var(--color-hover)', opacity: 0.4 }}
          content={<ChartTooltip valueFormatter={(v) => `${v.toFixed(2)} ${unit}`} />}
        />
        <Bar dataKey="egress" name="Egress" fill="var(--color-chart-1)" radius={[3, 3, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="ingress" name="Ingress" fill="var(--color-chart-2)" radius={[3, 3, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </ResponsiveContainer>
  );
}

/** Donut with a centered headline value (e.g. HTTP/3 share). */
export function ShareDonut({
  data,
  centerValue,
  centerLabel,
  height = 220,
}: {
  data: ShareItem[];
  centerValue: string;
  centerLabel: string;
  height?: number;
}) {
  return (
    <div className={styles.donut}>
      <ResponsiveContainer width="100%" height={height}>
        <PieChart>
          <Pie data={data} dataKey="value" nameKey="name" innerRadius={58} outerRadius={88} paddingAngle={2} strokeWidth={0} isAnimationActive={false}>
            {data.map((entry) => (
              <Cell key={entry.name} fill={entry.color} />
            ))}
          </Pie>
          <Tooltip content={<ChartTooltip />} />
        </PieChart>
      </ResponsiveContainer>
      <div className={styles.donutCenter}>
        <span className={styles.donutValue}>{centerValue}</span>
        <span className={styles.donutLabel}>{centerLabel}</span>
      </div>
    </div>
  );
}

export function ChartLegend({ items }: { items: { label: string; color: string }[] }) {
  return (
    <div className={styles.legend}>
      {items.map((item) => (
        <div key={item.label} className={styles.legendItem}>
          <span className={styles.legendDot} style={{ background: item.color }} />
          <span className={styles.legendLabel}>{item.label}</span>
        </div>
      ))}
    </div>
  );
}
