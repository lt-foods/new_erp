import type { Metadata } from "next";
import { Geist } from "next/font/google";
import {
  BRAND_NAME,
  SITE_URL,
  TAGLINE,
  SUB_TAGLINE,
  SEO_KEYWORDS,
  PLANS,
  FAQS,
  CONTACT,
} from "@/lib/site";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const title = `${BRAND_NAME}｜${TAGLINE} — 社群團購系統`;
const description = `${BRAND_NAME} 是團購店與加盟總部專用的營運系統：開團接龍下單、撿貨派貨、庫存採購、會員 App、多店統管、電子發票對帳一條龍。月租制，免費試用 14 天。`;

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: title,
    template: `%s｜${BRAND_NAME}`,
  },
  description,
  keywords: SEO_KEYWORDS,
  applicationName: BRAND_NAME,
  alternates: {
    canonical: "/",
    languages: { "zh-Hant-TW": "/" },
  },
  openGraph: {
    type: "website",
    locale: "zh_TW",
    url: SITE_URL,
    siteName: BRAND_NAME,
    title,
    description,
    images: [{ url: "/og.png", width: 1200, height: 630, alt: BRAND_NAME }],
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
    images: ["/og.png"],
  },
  robots: {
    index: true,
    follow: true,
    googleBot: { index: true, follow: true, "max-image-preview": "large" },
  },
};

/** 結構化資料：Organization + SoftwareApplication(含 Offers) + FAQPage */
function StructuredData() {
  const offers = PLANS.filter((p) => p.monthly != null).map((p) => ({
    "@type": "Offer",
    name: p.name,
    price: p.monthly,
    priceCurrency: "TWD",
    description: `${p.audience}・月繳 NT$${p.monthly}`,
    url: `${SITE_URL}/#pricing`,
  }));

  const data = [
    {
      "@context": "https://schema.org",
      "@type": "Organization",
      name: BRAND_NAME,
      url: SITE_URL,
      email: CONTACT.email,
      areaServed: "TW",
      slogan: TAGLINE,
    },
    {
      "@context": "https://schema.org",
      "@type": "SoftwareApplication",
      name: BRAND_NAME,
      applicationCategory: "BusinessApplication",
      operatingSystem: "Web, iOS, Android",
      description: `${TAGLINE} — ${SUB_TAGLINE}`,
      offers: {
        "@type": "AggregateOffer",
        priceCurrency: "TWD",
        lowPrice: Math.min(...PLANS.filter((p) => p.monthly).map((p) => p.monthly as number)),
        offerCount: offers.length,
        offers,
      },
    },
    {
      "@context": "https://schema.org",
      "@type": "FAQPage",
      mainEntity: FAQS.map((f) => ({
        "@type": "Question",
        name: f.q,
        acceptedAnswer: { "@type": "Answer", text: f.a },
      })),
    },
  ];

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }}
    />
  );
}

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-Hant" className={`${geistSans.variable} antialiased`}>
      <body className="font-sans">
        <StructuredData />
        {children}
      </body>
    </html>
  );
}
