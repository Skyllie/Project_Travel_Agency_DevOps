-- Inserting roles
INSERT INTO Role ( role_name)
VALUES ( 'Administrator'),
       ( 'ADMIN'),
       ( 'Systems Administrator');

-- Inserting users
INSERT INTO User (login, name, surname, email, password, role_id, account_non_expired, account_non_locked, isActual, credentials_non_expired, enabled)
VALUES ('michael.scott', 'Michael', 'Scott', 'michael.scott@example.com', 'Bestboss123', 1, true, true, true, true, true),
       ('jim.halpert', 'Jim', 'Halpert', 'jim.halpert@example.com', 'Pranks123', 2, true, true, true, true, true),
       ('pam.beesly', 'Pam', 'Beesly', 'pam.beesly@example.com', 'Painting123', 2, true, true, true, true, true),
       ('dwight.schrute', 'Dwight', 'Schrute', 'dwight.schrute@example.com', 'Beets123', 2, true, true, true, true, true),
       ('angela.martin', 'Angela', 'Martin', 'angela.martin@example.com', 'Cats123', 3, true, true, true, true, true),
       ('oscar.martinez', 'Oscar', 'Martinez', 'oscar.martinez@example.com', 'Smart123', 2, true, true, true, true, true),
       ('stanley.hudson', 'Stanley', 'Hudson', 'stanley.hudson@example.com', 'Crossword123', 2, true, true, true, true, true),
       ('phyllis.vance', 'Phyllis', 'Vance', 'phyllis.vance@example.com', 'Knitting123', 2, true, true, true, true, true),
       ('ryan.howard', 'Ryan', 'Howard', 'ryan.howard@example.com', 'Fire123', 1, true, true, true, true, true),
       ('andy.bernard', 'Andy', 'Bernard', 'andy.bernard@example.com', 'Singing123', 2, true, true, true, true, true),
       ('erin.hannon', 'Erin', 'Hannon', 'erin.hannon@example.com', 'Cheerful123', 2, true, true, true, true, true),
       ('kevin.malone', 'Kevin', 'Malone', 'kevin.malone@example.com', 'Chili123', 2, true, true, true, true, true),
       ('toby.flenderson', 'Toby', 'Flenderson', 'toby.flenderson@example.com', 'Hr123', 2, true, true, true, true, true),
       ('kelly.kapoor', 'Kelly', 'Kapoor', 'kelly.kapoor@example.com', 'Fashion123', 2, true, true, true, true, true),
       ('creed.brattom', 'Creed', 'Bratton', 'creed.bratton@example.com', 'Mysterious123', 2, true, true, true, true, true),
       ('jane.doe', 'Jane', 'Doe', 'jane.doe@example.com', 'Password123', 2, true, true, true, true, true),
       ('john.doe', 'John', 'Doe', 'john.doe@example.com', 'Password456', 2, true, true, true, true, true),
       ('mary.johnson', 'Mary', 'Johnson', 'mary.johnson@example.com', 'MJSecure789', 2, true, true, true, true, true),
       ('james.smith', 'James', 'Smith', 'james.smith@example.com', 'SmithSecure101', 1, true, true, true, true, true),
       ('linda.brown', 'Linda', 'Brown', 'linda.brown@example.com', 'Brownies202', 2, true, true, true, true, true),
       ('robert.davis', 'Robert', 'Davis', 'robert.davis@example.com', 'Davis1234', 1, true, true, true, true, true),
       ('jennifer.wilson', 'Jennifer', 'Wilson', 'jennifer.wilson@example.com', 'Wilson1234', 2, true, true, true, true, true),
       ('michael.miller', 'Michael', 'Miller', 'michael.miller@example.com', 'Miller4567', 3, true, true, true, true, true),
       ('sarah.moore', 'Sarah', 'Moore', 'sarah.moore@example.com', 'Moore8910', 2, true, true, true, true, true),
       ('william.taylor', 'William', 'Taylor', 'william.taylor@example.com', 'Taylor1112', 2, true, true, true, true, true),
       ('jessica.thomas', 'Jessica', 'Thomas', 'jessica.thomas@example.com', 'Thomas1314', 2, true, true, true, true, true),
       ('david.jackson', 'David', 'Jackson', 'david.jackson@example.com', 'Jackson1516', 1, true, true, true, true, true),
       ('megan.white', 'Megan', 'White', 'megan.white@example.com', 'White1718', 2, true, true, true, true, true),
       ('ryan.harris', 'Ryan', 'Harris', 'ryan.harris@example.com', 'Harris1920', 2, true, true, true, true, true),
       ('olivia.martin', 'Olivia', 'Martin', 'olivia.martin@example.com', 'Martin2122', 2, true, true, true, true, true);

-- Inserting countries
INSERT INTO Country (name)
VALUES ('Germany'),
       ('France'),
       ('Italy'),
       ('Spain'),
       ('Canada'),
       ('Mexico'),
       ('Australia'),
       ('Japan');

-- Inserting cities
INSERT INTO City (name, country_id)
VALUES ('Berlin', (SELECT countryId FROM Country WHERE name = 'Germany')),
       ('Munich', (SELECT countryId FROM Country WHERE name = 'Germany')),
       ('Paris', (SELECT countryId FROM Country WHERE name = 'France')),
       ('Lyon', (SELECT countryId FROM Country WHERE name = 'France')),
       ('Rome', (SELECT countryId FROM Country WHERE name = 'Italy')),
       ('Venice', (SELECT countryId FROM Country WHERE name = 'Italy')),
       ('Barcelona', (SELECT countryId FROM Country WHERE name = 'Spain')),
       ('Madrid', (SELECT countryId FROM Country WHERE name = 'Spain')),
       ('Toronto', (SELECT countryId FROM Country WHERE name = 'Canada')),
       ('Vancouver', (SELECT countryId FROM Country WHERE name = 'Canada')),
       ('Mexico City', (SELECT countryId FROM Country WHERE name = 'Mexico')),
       ('Cancun', (SELECT countryId FROM Country WHERE name = 'Mexico')),
       ('Sydney', (SELECT countryId FROM Country WHERE name = 'Australia')),
       ('Melbourne', (SELECT countryId FROM Country WHERE name = 'Australia')),
       ('Tokyo', (SELECT countryId FROM Country WHERE name = 'Japan')),
       ('Osaka', (SELECT countryId FROM Country WHERE name = 'Japan'));

-- Inserting hotels
INSERT INTO Hotel (name, city_id, location, description)
VALUES ('Berlin Grand', (SELECT cityId FROM City WHERE name = 'Berlin'), '2 Berlin St, Berlin', 'Luxury hotel in Berlin'),
       ('Paris Towers', (SELECT cityId FROM City WHERE name = 'Paris'), '22 Paris St, Paris', 'Historic hotel in Paris'),
       ('Rome Palazzo', (SELECT cityId FROM City WHERE name = 'Rome'), '45 Rome St, Rome', 'Beautiful hotel in Rome'),
       ('Barcelona Beach Hotel', (SELECT cityId FROM City WHERE name = 'Barcelona'), '12 Barcelona St, Barcelona', 'Beachfront hotel in Barcelona'),
       ('Toronto Suites', (SELECT cityId FROM City WHERE name = 'Toronto'), '67 Toronto St, Toronto', 'Modern hotel in Toronto'),
       ('Mexico City Inn', (SELECT cityId FROM City WHERE name = 'Mexico City'), '28 Mexico City St, Mexico City', 'Traditional hotel in Mexico City'),
       ('Sydney Harbour Hotel', (SELECT cityId FROM City WHERE name = 'Sydney'), '38 Sydney St, Sydney', 'Hotel with stunning harbour views'),
       ('Tokyo Towers', (SELECT cityId FROM City WHERE name = 'Tokyo'), '12 Tokyo St, Tokyo', 'Beautiful hotel in Tokyo');

-- Inserting RoomClassification
INSERT INTO RoomClassification (name)
VALUES ('Standard'),
       ('Deluxe'),
       ('Suite');
