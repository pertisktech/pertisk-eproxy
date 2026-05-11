/**
 * Date formatting utilities with timezone support
 */

const STORAGE_KEY = 'pertisk_timezone';

// Common timezone options
export const TIMEZONES = [
  { value: 'local', label: 'Browser Local Time' },
  { value: 'UTC', label: 'UTC' },
  { value: 'America/New_York', label: 'America/New York (ET)' },
  { value: 'America/Chicago', label: 'America/Chicago (CT)' },
  { value: 'America/Denver', label: 'America/Denver (MT)' },
  { value: 'America/Los_Angeles', label: 'America/Los Angeles (PT)' },
  { value: 'Europe/London', label: 'Europe/London (GMT)' },
  { value: 'Europe/Paris', label: 'Europe/Paris (CET)' },
  { value: 'Europe/Berlin', label: 'Europe/Berlin (CET)' },
  { value: 'Asia/Bangkok', label: 'Asia/Bangkok (ICT)' },
  { value: 'Asia/Tokyo', label: 'Asia/Tokyo (JST)' },
  { value: 'Asia/Shanghai', label: 'Asia/Shanghai (CST)' },
  { value: 'Asia/Singapore', label: 'Asia/Singapore (SGT)' },
  { value: 'Asia/Dubai', label: 'Asia/Dubai (GST)' },
  { value: 'Australia/Sydney', label: 'Australia/Sydney (AEDT)' },
];

export function getTimezone(): string {
  if (typeof window === 'undefined') return 'local';
  return localStorage.getItem(STORAGE_KEY) || 'local';
}

export function setTimezone(timezone: string): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_KEY, timezone);
}

/**
 * Format a date with the user's selected timezone
 */
export function formatDate(
  dateString: string | undefined,
  options: Intl.DateTimeFormatOptions = { dateStyle: 'medium', timeStyle: 'short' }
): string {
  if (!dateString) return '—';
  
  try {
    const d = new Date(dateString);
    if (Number.isNaN(d.getTime())) return dateString;
    
    const timezone = getTimezone();
    const formatOptions = timezone === 'local' 
      ? options 
      : { ...options, timeZone: timezone };
    
    return d.toLocaleString(undefined, formatOptions);
  } catch {
    return dateString;
  }
}

/**
 * Format date only (no time)
 */
export function formatDateOnly(dateString: string | undefined): string {
  return formatDate(dateString, { dateStyle: 'medium' });
}

/**
 * Format time only (no date)
 */
export function formatTimeOnly(dateString: string | undefined): string {
  return formatDate(dateString, { timeStyle: 'short' });
}

/**
 * Format with full date and time
 */
export function formatDateTime(dateString: string | undefined): string {
  return formatDate(dateString, { 
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: true
  });
}

/**
 * Format relative time (e.g., "2 hours ago", "in 3 days")
 */
export function formatRelativeTime(dateString: string | undefined): string {
  if (!dateString) return '—';
  
  try {
    const d = new Date(dateString);
    if (Number.isNaN(d.getTime())) return dateString;
    
    const now = new Date();
    const diffMs = d.getTime() - now.getTime();
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
    const diffMinutes = Math.floor(diffMs / (1000 * 60));
    
    if (Math.abs(diffDays) >= 7) {
      return formatDateOnly(dateString);
    } else if (diffDays > 1) {
      return `in ${diffDays} days`;
    } else if (diffDays === 1) {
      return 'tomorrow';
    } else if (diffDays === 0 && diffHours > 0) {
      return `in ${diffHours} hour${diffHours === 1 ? '' : 's'}`;
    } else if (diffDays === 0 && diffHours === 0 && diffMinutes > 0) {
      return `in ${diffMinutes} minute${diffMinutes === 1 ? '' : 's'}`;
    } else if (diffDays === 0 && diffHours === 0 && diffMinutes === 0) {
      return 'now';
    } else if (diffDays === -1) {
      return 'yesterday';
    } else if (diffDays < -1 && diffDays > -7) {
      return `${Math.abs(diffDays)} days ago`;
    } else if (diffHours < 0 && diffHours > -24) {
      return `${Math.abs(diffHours)} hour${Math.abs(diffHours) === 1 ? '' : 's'} ago`;
    } else if (diffMinutes < 0) {
      return `${Math.abs(diffMinutes)} minute${Math.abs(diffMinutes) === 1 ? '' : 's'} ago`;
    }
    
    return formatDateOnly(dateString);
  } catch {
    return dateString;
  }
}

/**
 * Get timezone abbreviation for display
 */
export function getTimezoneAbbr(): string {
  const timezone = getTimezone();
  if (timezone === 'local') {
    return new Date().toLocaleTimeString('en-US', { timeZoneName: 'short' }).split(' ').pop() || '';
  }
  
  try {
    return new Date().toLocaleTimeString('en-US', { 
      timeZone: timezone, 
      timeZoneName: 'short' 
    }).split(' ').pop() || timezone;
  } catch {
    return timezone;
  }
}
