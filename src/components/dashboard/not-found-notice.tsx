/**
 * `render plain: "Company not found", status: :not_found`.
 *
 * Plain text on purpose: this renders inside Fluid's dropzone iframe, where a
 * styled error page is less legible than a sentence, not more.
 */
export function CompanyNotFound() {
  return (
    <div className="p-6 font-mono text-sm text-muted-foreground">
      Company not found
    </div>
  );
}
