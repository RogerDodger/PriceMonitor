CREATE TABLE cards (
	id INTEGER PRIMARY KEY,
	name TEXT,
	setname TEXT,
	foil BIT,
	UNIQUE (name, foil, setname)
);

CREATE TABLE prices (
	card_id INTEGER REFERENCES cards(id),
	shop TEXT,
	type BIT, -- BUY => 0, SELL => 1
	price REAL,
	ts TIMESTAMP,
	PRIMARY KEY (card_id, shop, type)
);

CREATE INDEX cards_name_set_foil ON cards (name, setname, foil);
CREATE INDEX prices_card_id ON prices (card_id);

CREATE VIEW diffs AS
SELECT
	cards.name AS card,
	cards.setname AS setname,
	cards.foil AS foil,
	buy.price AS buyprice,
	buy.shop AS buyer,
	sell.price AS sellprice,
	sell.shop AS seller,
	(buy.price - sell.price) AS profit,
	((buy.price - sell.price) / (sell.price)) * 100 AS roi
FROM
	cards, prices buy, prices sell
WHERE
	buy.card_id=cards.id AND sell.card_id=cards.id AND
	buy.type=0 AND sell.type=1
ORDER BY profit DESC;
