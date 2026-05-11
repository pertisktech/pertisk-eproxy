import FaIcon from "@/components/FaIcon";
import { useState, useRef, useEffect } from 'react';
import styles from './TimezoneDropdown.module.css';

interface TimezoneOption {
  value: string;
  label: string;
}

interface TimezoneDropdownProps {
  value: string;
  options: TimezoneOption[];
  onChange: (value: string) => void;
  id?: string;
}

export default function TimezoneDropdown({ value, options, onChange, id }: TimezoneDropdownProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [highlightedIndex, setHighlightedIndex] = useState(0);
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);

  const selectedOption = options.find((o) => o.value === value);

  const filtered = options.filter((o) =>
    o.label.toLowerCase().includes(search.toLowerCase()) ||
    o.value.toLowerCase().includes(search.toLowerCase())
  );

  useEffect(() => {
    setHighlightedIndex(0);
  }, [search]);

  useEffect(() => {
    if (!isOpen) {
      setSearch('');
    }
  }, [isOpen]);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  useEffect(() => {
    if (isOpen && listRef.current) {
      const highlighted = listRef.current.children[highlightedIndex] as HTMLElement;
      if (highlighted) {
        highlighted.scrollIntoView({ block: 'nearest' });
      }
    }
  }, [highlightedIndex, isOpen]);

  function handleKeyDown(e: React.KeyboardEvent) {
    if (!isOpen) {
      if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown') {
        e.preventDefault();
        setIsOpen(true);
      }
      return;
    }

    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        setHighlightedIndex((i) => Math.min(i + 1, filtered.length - 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setHighlightedIndex((i) => Math.max(i - 1, 0));
        break;
      case 'Enter':
        e.preventDefault();
        if (filtered[highlightedIndex]) {
          onChange(filtered[highlightedIndex].value);
          setIsOpen(false);
        }
        break;
      case 'Escape':
        e.preventDefault();
        setIsOpen(false);
        break;
      case 'Tab':
        setIsOpen(false);
        break;
    }
  }

  function handleSelect(option: TimezoneOption) {
    onChange(option.value);
    setIsOpen(false);
  }

  return (
    <div className={styles.container} ref={containerRef}>
      <button
        type="button"
        id={id}
        className={`${styles.trigger} ${isOpen ? styles.triggerOpen : ''}`}
        onClick={() => setIsOpen(!isOpen)}
        onKeyDown={handleKeyDown}
        aria-haspopup="listbox"
        aria-expanded={isOpen}
      >
        <span className={styles.triggerContent}>
          <FaIcon className="fas fa-globe" aria-hidden />
          <span className={styles.triggerText}>
            {selectedOption?.label || 'Select timezone…'}
          </span>
        </span>
        <FaIcon className={`fas fa-chevron-down ${styles.chevron} ${isOpen ? styles.chevronOpen : ''}`} aria-hidden />
      </button>

      {isOpen && (
        <div className={styles.dropdown}>
          <div className={styles.searchWrap}>
            <FaIcon className="fas fa-search" aria-hidden />
            <input
              ref={inputRef}
              type="text"
              className={styles.search}
              placeholder="Search timezones…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              onKeyDown={handleKeyDown}
              autoFocus
            />
            {search && (
              <button
                type="button"
                className={styles.clearBtn}
                onClick={() => setSearch('')}
                aria-label="Clear search"
              >
                <FaIcon className="fas fa-times" aria-hidden />
              </button>
            )}
          </div>

          <ul ref={listRef} className={styles.list} role="listbox">
            {filtered.length === 0 ? (
              <li className={styles.noResults}>
                <FaIcon className="fas fa-search" aria-hidden />
                No timezones found
              </li>
            ) : (
              filtered.map((option, index) => (
                <li
                  key={option.value}
                  role="option"
                  aria-selected={option.value === value}
                  className={`${styles.option} ${
                    option.value === value ? styles.optionSelected : ''
                  } ${index === highlightedIndex ? styles.optionHighlighted : ''}`}
                  onClick={() => handleSelect(option)}
                  onMouseEnter={() => setHighlightedIndex(index)}
                >
                  <span className={styles.optionLabel}>{option.label}</span>
                  {option.value === value && (
                    <FaIcon className="fas fa-check" aria-hidden />
                  )}
                </li>
              ))
            )}
          </ul>
        </div>
      )}
    </div>
  );
}
