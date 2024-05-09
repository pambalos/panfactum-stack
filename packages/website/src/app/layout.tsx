import 'katex/dist/katex.min.css'
import './globals.css'
import type { Metadata } from 'next'
import Script from 'next/script'
import React, { type ReactNode } from 'react'

import ThemeRegistry from '@/components/ThemeRegistry'
import WebLayout from '@/components/layout/web/primary/WebLayout'
import WebContextProvider from '@/lib/contexts/web/WebContextProvider'

import { kanit } from './font'

export const metadata: Metadata = {
  title: {
    default: 'Panfactum',
    template: '%s | Panfactum'
  },
  description: 'Cloud Native System for Platform Engineering'
}

export default function RootLayout (
  { children } : {children: ReactNode}
) {
  return (

    <html lang="en">
      <body
        id="root"
        className={`${kanit.className} overflow-visible w-screen`}
      >
        {process.env.NODE_ENV === 'production' && (
          <Script
            src="https://cdn.pagesense.io/js/panfactumllc/45522f8c2b43455886f060a28de4fa9e.js"
            strategy="afterInteractive"
          />
        )}
        <ThemeRegistry options={{ key: 'mui', prepend: true }}>
          <WebContextProvider>
            <WebLayout>
              {children}
            </WebLayout>
          </WebContextProvider>
        </ThemeRegistry>
      </body>
    </html>

  )
}
