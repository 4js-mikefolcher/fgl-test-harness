# FOURJS_START_COPYRIGHT(U,2018)
# Property of Four Js*
# (c) Copyright Four Js 2018, 2025. All Rights Reserved.
# * Trademark of Four Js Development Tools Europe Ltd
#   in the United States and elsewhere
#
# Four Js and its suppliers do not warrant or guarantee that these samples
# are accurate and suitable for your purposes. Their inclusion is purely for
# information purposes only.
# FOURJS_END_COPYRIGHT
MAIN
    TYPE price_t RECORD
        name STRING,
        price MONEY(5, 2)
    END RECORD

    DEFINE prices DYNAMIC ARRAY OF price_t
    DEFINE images DYNAMIC ARRAY OF STRING

    OPEN FORM f FROM "price"
    DISPLAY FORM f

    LET prices[1].name = "Globe"
    LET prices[1].price = 22.00
    LET images[1] = "globe.jpg"

    LET prices[2].name = "Wall clock"
    LET prices[2].price = 12.00
    LET images[2] = "wall-clock.jpg"

    LET prices[3].name = "Blue Scissors"
    LET prices[3].price = 4.35
    LET images[3] = "blue-scissors.jpg"

    LET prices[4].name = "Coloring pencils"
    LET prices[4].price = 1.30
    LET images[4] = "colouring-pencils.jpg"

    LET prices[5].name = "Golf ball and tee"
    LET prices[5].price = 3.00
    LET images[5] = "golf-ball-and-tee.jpg"

    DISPLAY ARRAY prices TO sr_prices.* ATTRIBUTES(UNBUFFERED)
        BEFORE ROW
            DISPLAY images[arr_curr()] TO photo
        ON ACTION edit ATTRIBUTES(TEXT = "Edit price")
            OPEN FORM ep FROM "edit_price"
            DISPLAY FORM ep
            INPUT prices[arr_curr()].* WITHOUT DEFAULTS FROM name, price ATTRIBUTES(UNBUFFERED)
                ON ACTION cancel ATTRIBUTES(TEXT = "Exit")
                    EXIT INPUT
            END INPUT
            CLOSE FORM ep
        ON ACTION cancel ATTRIBUTES(TEXT = "Exit")
            EXIT DISPLAY
    END DISPLAY
END MAIN
