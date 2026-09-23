import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Dynamic Pricing",
  description: "Customer-type and price-type pricing for Fluid carts",
  icons: { icon: "/icon.svg", apple: "/icon.png" },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="h-full antialiased bg-gray-50">{children}</body>
    </html>
  );
}
