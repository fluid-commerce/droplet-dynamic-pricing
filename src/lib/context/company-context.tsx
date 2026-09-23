"use client";

import { createContext, useContext, type ReactNode } from "react";

/**
 * Company Context
 *
 * Provides company information to all components in the droplet.
 * This context is populated from URL parameters passed by Fluid.
 */

export interface CompanyContextValue {
  company: {
    id: string;
    fluidCompanyId: number;
    name: string | null;
    dropletInstallationUuid: string;
    active: boolean;
  } | null;
  isLoading: boolean;
  error: string | null;
}

const CompanyContext = createContext<CompanyContextValue | undefined>(
  undefined,
);

export function CompanyProvider({
  children,
  value,
}: {
  children: ReactNode;
  value: CompanyContextValue;
}) {
  return (
    <CompanyContext.Provider value={value}>{children}</CompanyContext.Provider>
  );
}

/**
 * Hook to access company context
 *
 * @throws Error if used outside CompanyProvider
 */
export function useCompany() {
  const context = useContext(CompanyContext);
  if (context === undefined) {
    throw new Error("useCompany must be used within a CompanyProvider");
  }
  return context;
}

/**
 * Hook to get the current company (throws if not available)
 */
export function useRequiredCompany() {
  const { company, isLoading, error } = useCompany();

  if (isLoading) {
    throw new Error("Company data is still loading");
  }

  if (error) {
    throw new Error(`Company data error: ${error}`);
  }

  if (!company) {
    throw new Error("No company data available");
  }

  return company;
}
