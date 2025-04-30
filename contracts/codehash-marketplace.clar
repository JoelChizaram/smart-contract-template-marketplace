;; CodeHash Marketplace: Smart Contract Template Marketplace
;; This contract manages the listing, purchase, and licensing of smart contract templates
;; on the CodeHash platform. It allows developers to monetize their expertise by offering
;; verified templates with different pricing models that other developers can purchase.

;; ===============
;; Error Constants
;; ===============

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-TEMPLATE-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-PRICE (err u104))
(define-constant ERR-INVALID-PAYMENT-MODEL (err u105))
(define-constant ERR-TEMPLATE-DISABLED (err u106))
(define-constant ERR-ALREADY-LICENSED (err u107))
(define-constant ERR-INVALID-RATING (err u108))
(define-constant ERR-NO-LICENSE (err u109))
(define-constant ERR-ROYALTY-SUM-INVALID (err u110))

;; ==================
;; Constant Variables
;; ==================

(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENT u5) ;; 5% platform fee
(define-constant MAX-ROYALTY-RECIPIENTS u5) ;; Maximum number of royalty recipients
(define-constant MAX-RATING u5) ;; Maximum rating value (5 stars)
(define-constant MIN-PRICE u1000) ;; Minimum price in uSTX

;; Payment model types
(define-constant PAYMENT-MODEL-ONE-TIME u1)
(define-constant PAYMENT-MODEL-SUBSCRIPTION u2)
(define-constant PAYMENT-MODEL-USAGE-BASED u3)

;; ===============
;; Data Structures
;; ===============

;; Template data structure
(define-map templates
  { template-id: uint }
  {
    name: (string-ascii 100),
    description: (string-utf8 500),
    creator: principal,
    price: uint,
    payment-model: uint,
    active: bool,
    creation-time: uint,
    version: (string-ascii 20),
    category: (string-ascii 50),
    total-sales: uint
  }
)

;; Template extended metadata - stored separately for gas optimization
(define-map template-metadata
  { template-id: uint }
  {
    documentation-url: (string-utf8 200),
    repository-url: (optional (string-utf8 200)),
    preview-code: (optional (string-utf8 2000)),
    license-terms: (string-utf8 500)
  }
)

;; Tracks royalty distributions for templates
(define-map template-royalties
  { template-id: uint }
  {
    recipients: (list 5 { recipient: principal, share: uint }),
    total-share: uint ;; Should sum to 100 for 100%
  }
)

;; Tracks template purchases and licensing
(define-map licenses
  { template-id: uint, licensee: principal }
  {
    purchase-time: uint,
    payment-amount: uint,
    expiration-time: (optional uint), ;; For subscription-based models
    usage-limit: (optional uint), ;; For usage-based models
    usage-count: (optional uint) ;; Current usage count
  }
)

;; User ratings and reviews for templates
(define-map template-ratings
  { template-id: uint, reviewer: principal }
  {
    rating: uint, ;; 1-5 stars
    review-text: (optional (string-utf8 500)),
    review-time: uint
  }
)

;; Creator profiles
(define-map creator-profiles
  { creator: principal }
  {
    name: (string-ascii 100),
    bio: (string-utf8 500),
    website: (optional (string-utf8 200)),
    total-templates: uint,
    total-sales: uint,
    join-time: uint
  }
)

;; Counter for generating template IDs
(define-data-var next-template-id uint u1)

;; ==================
;; Private Functions
;; ==================

;; Calculate platform fee amount based on payment amount
(define-private (calculate-platform-fee (payment-amount uint))
  (/ (* payment-amount PLATFORM-FEE-PERCENT) u100)
)

;; Distribute royalties to all recipients
(define-private (distribute-royalties (template-id uint) (payment-amount uint))
  (let (
    (royalty-info (unwrap! (map-get? template-royalties { template-id: template-id }) (ok true))) ;; No royalties defined
    (creator-amount (- payment-amount (calculate-platform-fee payment-amount)))
  )
    (if (> (len (get recipients royalty-info)) u0)
      ;; Distribute according to royalty shares
      (let (
        (distribute-result (fold distribute-to-recipient 
          (get recipients royalty-info) 
          { remaining-amount: creator-amount, success: true }))
      )
        (ok (get success distribute-result))
      )
      ;; No royalty recipients, pay full amount to creator
      (let (
        (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
        (creator (get creator template))
      )
        (stx-transfer? creator-amount tx-sender creator)
      )
    )
  )
)

;; Helper function to distribute royalties to a recipient
(define-private (distribute-to-recipient 
  (recipient { recipient: principal, share: uint }) 
  (state { remaining-amount: uint, success: bool })
)
  (let (
    (recipient-amount (/ (* (get remaining-amount state) (get share recipient)) u100))
    (new-remaining (- (get remaining-amount state) recipient-amount))
    (transfer-result (stx-transfer? recipient-amount tx-sender (get recipient recipient)))
  )
    {
      remaining-amount: new-remaining,
      success: (and (get success state) (is-ok transfer-result))
    }
  )
)

;; Check if a user has a valid license for a template
(define-private (has-valid-license (template-id uint) (user principal))
  (match (map-get? licenses { template-id: template-id, licensee: user })
    license
      (let (
        (template (unwrap! (map-get? templates { template-id: template-id }) false))
        (payment-model (get payment-model template))
      )
        (cond
          ;; One-time purchase is always valid
          (is-eq payment-model PAYMENT-MODEL-ONE-TIME) true
          
          ;; Subscription - check expiration
          (is-eq payment-model PAYMENT-MODEL-SUBSCRIPTION)
            (let (
              (expiry (default-to u0 (get expiration-time license)))
            )
              (< block-height expiry)
            )
            
          ;; Usage-based - check usage count
          (is-eq payment-model PAYMENT-MODEL-USAGE-BASED)
            (let (
              (limit (default-to u0 (get usage-limit license)))
              (count (default-to u0 (get usage-count license)))
            )
              (< count limit)
            )
            
          ;; Unknown payment model
          false
        )
      )
    false
  )
)

;; Update template sales counter
(define-private (update-template-sales (template-id uint))
  (match (map-get? templates { template-id: template-id })
    template
      (map-set templates
        { template-id: template-id }
        (merge template { total-sales: (+ (get total-sales template) u1) })
      )
    false
  )
)

;; Update creator sales counter
(define-private (update-creator-sales (creator principal))
  (match (map-get? creator-profiles { creator: creator })
    profile
      (map-set creator-profiles
        { creator: creator }
        (merge profile { total-sales: (+ (get total-sales profile) u1) })
      )
    false
  )
)

;; ===================
;; Read-Only Functions
;; ===================

;; Get template details
(define-read-only (get-template (template-id uint))
  (map-get? templates { template-id: template-id })
)

;; Get template metadata
(define-read-only (get-template-metadata (template-id uint))
  (map-get? template-metadata { template-id: template-id })
)

;; Get template royalty information
(define-read-only (get-template-royalties (template-id uint))
  (map-get? template-royalties { template-id: template-id })
)

;; Check if user has license for template
(define-read-only (check-license (template-id uint) (user principal))
  (has-valid-license template-id user)
)

;; Get license details
(define-read-only (get-license-details (template-id uint) (user principal))
  (map-get? licenses { template-id: template-id, licensee: user })
)

;; Get template rating and review
(define-read-only (get-template-rating (template-id uint) (reviewer principal))
  (map-get? template-ratings { template-id: template-id, reviewer: reviewer })
)

;; Get creator profile
(define-read-only (get-creator-profile (creator principal))
  (map-get? creator-profiles { creator: creator })
)

;; Calculate average rating for a template
(define-read-only (get-template-average-rating (template-id uint))
  ;; This is a stub - in a full implementation, this would scan all ratings
  ;; Clarity doesn't support scanning maps directly, so this would require indexing
  ;; off-chain or implementing a counter system for each rating value
  u0
)

;; ================
;; Public Functions
;; ================

;; Create a new template listing
(define-public (create-template
  (name (string-ascii 100))
  (description (string-utf8 500))
  (price uint)
  (payment-model uint)
  (version (string-ascii 20))
  (category (string-ascii 50))
  (documentation-url (string-utf8 200))
  (repository-url (optional (string-utf8 200)))
  (preview-code (optional (string-utf8 2000)))
  (license-terms (string-utf8 500))
)
  (let (
    (template-id (var-get next-template-id))
    (creator tx-sender)
  )
    ;; Input validation
    (asserts! (>= price MIN-PRICE) ERR-INVALID-PRICE)
    (asserts! (or (is-eq payment-model PAYMENT-MODEL-ONE-TIME)
                  (is-eq payment-model PAYMENT-MODEL-SUBSCRIPTION)
                  (is-eq payment-model PAYMENT-MODEL-USAGE-BASED)) ERR-INVALID-PAYMENT-MODEL)
    
    ;; Store template data
    (map-set templates 
      { template-id: template-id }
      {
        name: name,
        description: description,
        creator: creator,
        price: price,
        payment-model: payment-model,
        active: true,
        creation-time: block-height,
        version: version,
        category: category,
        total-sales: u0
      }
    )
    
    ;; Store template metadata
    (map-set template-metadata
      { template-id: template-id }
      {
        documentation-url: documentation-url,
        repository-url: repository-url,
        preview-code: preview-code,
        license-terms: license-terms
      }
    )
    
    ;; Update creator profile
    (match (map-get? creator-profiles { creator: creator })
      profile (map-set creator-profiles
        { creator: creator }
        (merge profile { total-templates: (+ (get total-templates profile) u1) })
      )
      ;; No profile exists, create a new one
      (map-set creator-profiles
        { creator: creator }
        {
          name: name, ;; Default to template name, can be updated later
          bio: description, ;; Default to template description, can be updated later
          website: none,
          total-templates: u1,
          total-sales: u0,
          join-time: block-height
        }
      )
    )
    
    ;; Increment template ID counter
    (var-set next-template-id (+ template-id u1))
    
    (ok template-id)
  )
)

;; Set royalty distribution for a template
(define-public (set-royalties (template-id uint) (recipients (list 5 { recipient: principal, share: uint })))
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (total-share (fold + (map get-share recipients) u0))
  )
    ;; Only template creator can set royalties
    (asserts! (is-eq tx-sender (get creator template)) ERR-NOT-AUTHORIZED)
    
    ;; Total share must be exactly 100%
    (asserts! (is-eq total-share u100) ERR-ROYALTY-SUM-INVALID)
    
    (map-set template-royalties
      { template-id: template-id }
      {
        recipients: recipients,
        total-share: total-share
      }
    )
    
    (ok true)
  )
)

;; Helper function to get share from royalty recipient object
(define-private (get-share (recipient { recipient: principal, share: uint }))
  (get share recipient)
)

;; Update template details
(define-public (update-template
  (template-id uint)
  (name (string-ascii 100))
  (description (string-utf8 500))
  (price uint)
  (active bool)
  (version (string-ascii 20))
  (category (string-ascii 50))
)
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
  )
    ;; Only template creator can update
    (asserts! (is-eq tx-sender (get creator template)) ERR-NOT-AUTHORIZED)
    (asserts! (>= price MIN-PRICE) ERR-INVALID-PRICE)
    
    (map-set templates 
      { template-id: template-id }
      (merge template {
        name: name,
        description: description,
        price: price,
        active: active,
        version: version,
        category: category
      })
    )
    
    (ok true)
  )
)

;; Update template metadata
(define-public (update-template-metadata
  (template-id uint)
  (documentation-url (string-utf8 200))
  (repository-url (optional (string-utf8 200)))
  (preview-code (optional (string-utf8 2000)))
  (license-terms (string-utf8 500))
)
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (metadata (unwrap! (map-get? template-metadata { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
  )
    ;; Only template creator can update
    (asserts! (is-eq tx-sender (get creator template)) ERR-NOT-AUTHORIZED)
    
    (map-set template-metadata
      { template-id: template-id }
      {
        documentation-url: documentation-url,
        repository-url: repository-url,
        preview-code: preview-code,
        license-terms: license-terms
      }
    )
    
    (ok true)
  )
)

;; Purchase a template license
(define-public (purchase-template (template-id uint) (usage-count (optional uint)))
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (price (get price template))
    (payment-model (get payment-model template))
    (buyer tx-sender)
  )
    ;; Validate template is active
    (asserts! (get active template) ERR-TEMPLATE-DISABLED)
    
    ;; Check if buyer already has a license for one-time purchases
    (asserts! (not (and 
      (is-eq payment-model PAYMENT-MODEL-ONE-TIME) 
      (has-valid-license template-id buyer))) 
      ERR-ALREADY-LICENSED)
    
    ;; Transfer payment to contract
    (asserts! (>= (stx-get-balance buyer) price) ERR-INSUFFICIENT-FUNDS)
    
    ;; Calculate platform fee and creator payment
    (let (
      (platform-fee (calculate-platform-fee price))
      (creator-payment (- price platform-fee))
    )
      ;; Transfer platform fee
      (try! (stx-transfer? platform-fee buyer CONTRACT-OWNER))
      
      ;; Distribute royalties to creator(s)
      (try! (distribute-royalties template-id creator-payment))
      
      ;; Create license based on payment model
      (match payment-model
        PAYMENT-MODEL-ONE-TIME
          (map-set licenses
            { template-id: template-id, licensee: buyer }
            {
              purchase-time: block-height,
              payment-amount: price,
              expiration-time: none,
              usage-limit: none,
              usage-count: none
            }
          )
        
        PAYMENT-MODEL-SUBSCRIPTION
          (map-set licenses
            { template-id: template-id, licensee: buyer }
            {
              purchase-time: block-height,
              payment-amount: price,
              expiration-time: (some (+ block-height u52560)), ;; Assuming 52560 blocks = ~1 year
              usage-limit: none,
              usage-count: none
            }
          )
        
        PAYMENT-MODEL-USAGE-BASED
          (map-set licenses
            { template-id: template-id, licensee: buyer }
            {
              purchase-time: block-height,
              payment-amount: price,
              expiration-time: none,
              usage-limit: usage-count,
              usage-count: (some u0)
            }
          )
        
        ;; Should not reach here due to earlier validation
        ERR-INVALID-PAYMENT-MODEL
      )
      
      ;; Update sales counters
      (update-template-sales template-id)
      (update-creator-sales (get creator template))
      
      (ok true)
    )
  )
)

;; Record template usage for usage-based licenses
(define-public (record-template-usage (template-id uint) (user principal))
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (license (unwrap! (map-get? licenses { template-id: template-id, licensee: user }) ERR-NO-LICENSE))
  )
    ;; Only template creator can record usage
    (asserts! (is-eq tx-sender (get creator template)) ERR-NOT-AUTHORIZED)
    
    ;; Only applicable for usage-based licenses
    (asserts! (is-eq (get payment-model template) PAYMENT-MODEL-USAGE-BASED) ERR-INVALID-PAYMENT-MODEL)
    
    ;; Update usage count
    (let (
      (current-count (default-to u0 (get usage-count license)))
      (limit (default-to u0 (get usage-limit license)))
    )
      (asserts! (< current-count limit) ERR-NO-LICENSE)
      
      (map-set licenses
        { template-id: template-id, licensee: user }
        (merge license { usage-count: (some (+ current-count u1)) })
      )
      
      (ok true)
    )
  )
)

;; Rate and review a template
(define-public (rate-template (template-id uint) (rating uint) (review-text (optional (string-utf8 500))))
  (let (
    (template (unwrap! (map-get? templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (reviewer tx-sender)
  )
    ;; Validate input
    (asserts! (<= rating MAX-RATING) ERR-INVALID-RATING)
    (asserts! (> rating u0) ERR-INVALID-RATING)
    
    ;; Only licensees can rate templates
    (asserts! (has-valid-license template-id reviewer) ERR-NO-LICENSE)
    
    (map-set template-ratings
      { template-id: template-id, reviewer: reviewer }
      {
        rating: rating,
        review-text: review-text,
        review-time: block-height
      }
    )
    
    (ok true)
  )
)

;; Update creator profile
(define-public (update-creator-profile
  (name (string-ascii 100))
  (bio (string-utf8 500))
  (website (optional (string-utf8 200)))
)
  (let (
    (creator tx-sender)
    (profile (default-to 
      { 
        name: name, 
        bio: bio, 
        website: website, 
        total-templates: u0, 
        total-sales: u0, 
        join-time: block-height 
      } 
      (map-get? creator-profiles { creator: creator })))
  )
    (map-set creator-profiles
      { creator: creator }
      (merge profile {
        name: name,
        bio: bio,
        website: website
      })
    )
    
    (ok true)
  )
)