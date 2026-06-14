-- 07_scd2_demo.sql
-- Demonstrates SCD Type 2 behaviour of usp_Load_DimGeography.
--
-- Simulates an official country-name change (ISO3 / CountryDurableKey unchanged)
-- for 3 countries already present in DimGeography, then re-runs the
-- dimension load. The procedure closes the current row (IsCurrent=0,
-- ValidTo=yesterday) and inserts a new current row with the updated name.

USE SeismicDisasterDWH;
GO

UPDATE REF_CountryMaster SET CountryName = N'Republic of Indonesia'        WHERE ISO3 = 'IDN';
UPDATE REF_CountryMaster SET CountryName = N'Republic of the Philippines'  WHERE ISO3 = 'PHL';
UPDATE REF_CountryMaster SET CountryName = N'Republic of the Union of Myanmar' WHERE ISO3 = 'MMR';
GO

EXEC dbo.usp_Load_DimGeography;
GO

SELECT CountryDurableKey, GeographyKey, CountryName, ISO, ValidFrom, ValidTo, IsCurrent
FROM DimGeography
WHERE CountryDurableKey IN (
    SELECT CountryDurableKey FROM DimGeography GROUP BY CountryDurableKey HAVING COUNT(*) > 1
)
ORDER BY CountryDurableKey, ValidFrom;
GO
