"use client";

/**
 * A submit button that asks first — Rails' `data: { turbo_confirm: ... }` on the
 * price type Delete button, which Turbo turned into a browser confirm.
 */
export function ConfirmSubmit({
  message,
  className,
  children,
}: {
  message: string;
  className: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="submit"
      className={className}
      onClick={(event) => {
        if (!window.confirm(message)) event.preventDefault();
      }}
    >
      {children}
    </button>
  );
}
