import { useState, useEffect } from 'react';

/**
 * Returns a dynamic page size computed to fill the available viewport height.
 *
 * @param rowHeight  - Estimated pixel height of a single list row (default 44 px).
 * @param overhead   - Fixed pixel space consumed by chrome: app header, section
 *                     toolbar, table header, pagination bar, and padding
 *                     (default 240 px).
 * @param min        - Minimum page size (default 5).
 */
export function usePageSize(rowHeight = 44, overhead = 240, min = 5): number {
  const compute = () =>
    Math.max(min, Math.floor((window.innerHeight - overhead) / rowHeight));

  const [pageSize, setPageSize] = useState(compute);

  useEffect(() => {
    const onResize = () => setPageSize(compute());
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, [rowHeight, overhead, min]);

  return pageSize;
}
