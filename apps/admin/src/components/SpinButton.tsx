"use client";

import {
  forwardRef,
  useEffect,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type MouseEvent,
  type ReactNode,
} from "react";

export type SpinButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "onClick"> & {
  onClick?: (e: MouseEvent<HTMLButtonElement>) => unknown;
  loading?: boolean;
  children?: ReactNode;
};

const SpinButton = forwardRef<HTMLButtonElement, SpinButtonProps>(function SpinButton(
  { onClick, loading, disabled, className = "", children, ...rest },
  ref,
) {
  const [busy, setBusy] = useState(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const isLoading = loading ?? busy;
  const isDisabled = disabled || isLoading;

  async function handleClick(e: MouseEvent<HTMLButtonElement>) {
    if (!onClick || isDisabled) return;
    const ret = onClick(e);
    if (ret && typeof (ret as { then?: unknown }).then === "function") {
      setBusy(true);
      try {
        await ret;
      } finally {
        if (mountedRef.current) setBusy(false);
      }
    }
  }

  return (
    <button
      ref={ref}
      onClick={handleClick}
      disabled={isDisabled}
      className={`relative ${className}`}
      {...rest}
    >
      <span
        style={{
          display: "contents",
          visibility: isLoading ? "hidden" : undefined,
        }}
      >
        {children}
      </span>
      {isLoading ? (
        <span className="pointer-events-none absolute inset-0 flex items-center justify-center">
          <svg
            className="h-4 w-4 animate-spin"
            viewBox="0 0 24 24"
            fill="none"
            aria-hidden
          >
            <circle
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              strokeWidth="3"
              className="opacity-25"
            />
            <path
              d="M4 12a8 8 0 0 1 8-8"
              stroke="currentColor"
              strokeWidth="3"
              strokeLinecap="round"
            />
          </svg>
        </span>
      ) : null}
    </button>
  );
});

export default SpinButton;
