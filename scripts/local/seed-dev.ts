import { PrismaClient } from "@prisma/client";

import { assertLocalDatabase } from "./guard-local-db";

// Before the client is constructed, because the next thing this file does is
// empty every table it seeds. See guard-local-db.ts.
assertLocalDatabase(process.env.DATABASE_URL);

const prisma = new PrismaClient();
const DRI = "dri_local_test";

async function main() {
  // Idempotent: re-runnable while poking at the app.
  await prisma.cartPricingEvent.deleteMany({});
  await prisma.customerTypeTransaction.deleteMany({});
  await prisma.priceType.deleteMany({});
  await prisma.integrationSetting.deleteMany({});
  await prisma.event.deleteMany({});
  await prisma.company.deleteMany({});

  const company = await prisma.company.create({
    data: {
      name: "Acme Wellness (local)",
      fluidShop: "acme.fluid.app",
      fluidCompanyId: 980243114n,
      authenticationToken: "dit_local_fake_token",
      webhookVerificationToken: "wvt_local",
      companyDropletUuid: "cdu_local",
      dropletInstallationUuid: DRI,
      active: true,
    },
  });

  const events = [
    "item_added",
    "item_updated",
    "customer_logged_in",
    "country_changed",
    "customer_detached",
  ];
  await prisma.cartPricingEvent.createMany({
    data: Array.from({ length: 23 }, (_, i) => ({
      companyId: company.id,
      cartId: 700000 + i,
      email: `shopper${i}@example.com`,
      eventType: events[i % events.length]!,
      itemsCount: (i % 4) + 1,
      cartTotal: (49.99 + i * 7).toFixed(2),
      preferredPricingApplied: i % 3 === 0,
      createdAt: new Date(Date.now() - i * 3600_000),
    })),
  });

  await prisma.customerTypeTransaction.createMany({
    data: Array.from({ length: 14 }, (_, i) => ({
      companyId: company.id,
      customerId: 5000 + i,
      externalId: `EX${9000 + i}`,
      previousType: i % 2 === 0 ? "retail" : "preferred_customer",
      newType: i % 2 === 0 ? "preferred_customer" : "retail",
      source: i % 3 === 0 ? "sync_job" : "webhook",
      createdAt: new Date(Date.now() - i * 7200_000),
    })),
  });

  await prisma.priceType.createMany({
    data: [
      { companyId: company.id, name: "Wholesale" },
      { companyId: company.id, name: "Preferred" },
    ],
  });

  await prisma.integrationSetting.create({
    data: {
      companyId: company.id,
      enabled: true,
      settings: {
        preferred_customer_type_id: "2",
        retail_customer_type_id: "1",
        api_delay_seconds: "0.5",
      },
      // A stored secret, so the form can show "leave blank to keep it".
      credentials: {
        exigo_db_host: "sql.exigo.local",
        exigo_db_name: "ExigoDb",
        exigo_db_username: "svc",
        exigo_db_password: "THIS-MUST-NEVER-REACH-THE-BROWSER",
        api_base_url: "https://api.exigo.local",
        api_username: "api-user",
        api_password: "ALSO-SECRET",
      },
    },
  });

  console.log(`company id=${company.id}  dri=${DRI}`);
}

main().finally(() => prisma.$disconnect());
