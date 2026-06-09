/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // share-web is a thin SSR layer in front of core-go. The portrait
  // assets it embeds (og:image / twitter:image) live on the core-go
  // origin (configured via NEXT_PUBLIC_API_BASE_URL); the share page
  // itself never serves user-uploaded images, so the default image
  // optimization config is fine.
  poweredByHeader: false,
};

export default nextConfig;
