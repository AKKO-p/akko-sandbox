-- Fictional sample data: people, accounts and transactions that do not exist.
-- E-mail addresses use the reserved example.com and example.org domains.
CREATE SCHEMA crm;

CREATE TABLE crm.customers (
    id        integer PRIMARY KEY,
    full_name text    NOT NULL,
    email     text    NOT NULL,
    country   char(2) NOT NULL,
    segment   text    NOT NULL
);

INSERT INTO crm.customers VALUES
    (1,  'Lena Vogel',     'lena.vogel@example.com',     'DE', 'retail'),
    (2,  'Hugo Martin',    'hugo.martin@example.com',    'FR', 'retail'),
    (3,  'Sofia Ruiz',     'sofia.ruiz@example.org',     'ES', 'business'),
    (4,  'Noah Bennett',   'noah.bennett@example.com',   'US', 'retail'),
    (5,  'Giulia Conti',   'giulia.conti@example.org',   'IT', 'retail'),
    (6,  'Kenji Sato',     'kenji.sato@example.com',     'JP', 'business'),
    (7,  'Emma de Vries',  'emma.devries@example.org',   'NL', 'retail'),
    (8,  'Lucas Almeida',  'lucas.almeida@example.com',  'BR', 'business'),
    (9,  'Olivia Clarke',  'olivia.clarke@example.org',  'GB', 'retail'),
    (10, 'Chloe Tremblay', 'chloe.tremblay@example.com', 'CA', 'business');

CREATE TABLE crm.accounts (
    id          integer       PRIMARY KEY,
    customer_id integer       NOT NULL REFERENCES crm.customers (id),
    opened_on   date          NOT NULL,
    currency    char(3)       NOT NULL,
    balance     numeric(12,2) NOT NULL
);

INSERT INTO crm.accounts VALUES
    (101, 1,  '2021-03-14', 'EUR',  4210.50),
    (102, 2,  '2019-11-02', 'EUR',   980.00),
    (103, 3,  '2022-06-21', 'EUR', 15320.75),
    (104, 4,  '2020-01-09', 'USD',  2750.00),
    (105, 5,  '2023-02-27', 'EUR',   640.20),
    (106, 6,  '2018-08-30', 'JPY', 812000.00),
    (107, 7,  '2021-12-01', 'EUR',  3105.10),
    (108, 8,  '2022-09-15', 'BRL',  9800.00),
    (109, 9,  '2020-05-05', 'GBP',  1500.00),
    (110, 10, '2024-04-18', 'CAD',  7200.40),
    (111, 3,  '2024-07-03', 'EUR',  2300.00),
    (112, 6,  '2025-01-20', 'USD',  5600.00);

CREATE TABLE crm.transactions (
    id         integer       PRIMARY KEY,
    account_id integer       NOT NULL REFERENCES crm.accounts (id),
    booked_at  date          NOT NULL,
    amount     numeric(12,2) NOT NULL,
    category   text          NOT NULL
);

-- 120 transactions, the same on every start.
INSERT INTO crm.transactions
SELECT n,
       101 + (n % 12),
       DATE '2026-01-01' + (n * 2),
       round((((n * 37) % 400) - 150 + (n % 7) * 0.25)::numeric, 2),
       (ARRAY['groceries', 'travel', 'salary', 'rent', 'utilities', 'restaurants'])[1 + n % 6]
FROM generate_series(1, 120) AS n;
